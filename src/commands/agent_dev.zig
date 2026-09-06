//! The local agent development loop: point a live agent's webhook at a tunnel
//! to this machine, and re-send a recorded run to a handler running here.
const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");
const query = @import("../query.zig");

/// The server keeps the last 25 deliveries per agent. A run whose first event
/// has aged out cannot be replayed in full, so replay says so instead of
/// pretending a suffix is the whole run.
const DELIVERY_WINDOW = 25;
const TUNNEL_WAIT_MS = 30_000;
const TUNNEL_POLL_MS = 200;

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "replay")) return replay(context);
    if (std.mem.eql(u8, subcommand, "dev")) return dev(context);
    return error.UnknownCommand;
}

// ---------------------------------------------------------------- signing

fn hexLower(out: []u8, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0xf];
    }
}

/// `sha256=<hex HMAC-SHA256(secret, "<timestamp>.<body>")>`, byte for byte what
/// `signWebhookBody` produces in the app and what the SDK verifies.
pub fn signatureHeader(allocator: std.mem.Allocator, secret: []const u8, timestamp: []const u8, body: []const u8) ![]u8 {
    const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
    var mac: [Hmac.mac_length]u8 = undefined;
    var hmac = Hmac.init(secret);
    hmac.update(timestamp);
    hmac.update(".");
    hmac.update(body);
    hmac.final(&mac);
    var result = try allocator.alloc(u8, "sha256=".len + mac.len * 2);
    @memcpy(result[0.."sha256=".len], "sha256=");
    hexLower(result["sha256=".len..], &mac);
    return result;
}

// ---------------------------------------------------------------- helpers

fn fail(comptime format: []const u8, arguments: anytype, err: anyerror) anyerror {
    std.debug.print(format ++ "\n", arguments);
    return err;
}

fn note(comptime format: []const u8, arguments: anytype) void {
    std.debug.print(format ++ "\n", arguments);
}

fn stringField(value: std.json.Value, name: []const u8) ?[]const u8 {
    const field = if (value == .object) value.object.get(name) else null;
    return if (field != null and field.? == .string) field.?.string else null;
}

/// Header values must survive an HTTP request unchanged. A recorded payload is
/// server-written, but it is still remote data being spliced into a header.
fn isHeaderSafe(value: []const u8) bool {
    if (value.len == 0 or value.len > 200) return false;
    for (value) |byte| if (byte < 0x20 or byte > 0x7e) return false;
    return true;
}

fn fetchSubscription(context: *const Context, agent_id: []const u8) !http.Response {
    var path = try query.Builder.init(context.allocator, "/mcp/webhooks");
    defer path.deinit();
    try path.add("agent_id", agent_id);
    var response = try context.fetch(.GET, path.path(), null);
    errdefer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        try output.print(response.body);
        return error.ApiFailure;
    }
    return response;
}

fn environmentValue(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const owned = std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    if (owned.len == 0) {
        allocator.free(owned);
        return null;
    }
    return owned;
}

/// The secret is never accepted as an argument: argv is visible to every
/// process on the machine and lands in shell history.
fn webhookSecret(allocator: std.mem.Allocator) ![]u8 {
    if (try environmentValue(allocator, "HYPERTASK_WEBHOOK_SECRET")) |value| return value;
    if (try environmentValue(allocator, "WEBHOOK_SECRET")) |value| return value;
    return fail(
        "set HYPERTASK_WEBHOOK_SECRET (or WEBHOOK_SECRET) to the agent's webhook secret; it is never read from the command line",
        .{},
        error.MissingWebhookSecret,
    );
}

// ---------------------------------------------------------------- replay

const Recorded = struct {
    event: []const u8,
    delivery_id: []const u8,
    body: []const u8,
};

pub const ReplaySelection = struct {
    matches: []Recorded,
    saw_payload: bool,
    partial: bool,

    pub fn deinit(self: *ReplaySelection, allocator: std.mem.Allocator) void {
        for (self.matches) |recorded| allocator.free(recorded.body);
        allocator.free(self.matches);
        self.* = undefined;
    }
};

fn releaseMatches(allocator: std.mem.Allocator, matches: *std.ArrayListUnmanaged(Recorded)) void {
    for (matches.items) |recorded| allocator.free(recorded.body);
    matches.deinit(allocator);
}

/// Deliveries arrive newest first. Return this run's payloads oldest first, and
/// say whether the run may have started before the retained window.
pub fn selectRun(allocator: std.mem.Allocator, deliveries: []const std.json.Value, run_id: []const u8) !ReplaySelection {
    var matches: std.ArrayListUnmanaged(Recorded) = .{};
    errdefer releaseMatches(allocator, &matches);
    var saw_payload = false;
    var oldest_matches = false;
    var index = deliveries.len;
    while (index > 0) {
        index -= 1;
        const delivery = deliveries[index];
        const payload = if (delivery == .object) delivery.object.get("payload") orelse continue else continue;
        if (payload != .object) continue;
        saw_payload = true;
        const payload_run = stringField(payload, "runId") orelse continue;
        if (!std.mem.eql(u8, payload_run, run_id)) continue;
        if (index == deliveries.len - 1) oldest_matches = true;

        const event = stringField(payload, "event") orelse
            return fail("a recorded delivery has no event name", .{}, error.ApiFailure);
        const delivery_id = stringField(payload, "deliveryId") orelse
            return fail("a recorded delivery has no delivery id", .{}, error.ApiFailure);
        if (!isHeaderSafe(event) or !isHeaderSafe(delivery_id)) {
            return fail("a recorded delivery has an unusable event or delivery id", .{}, error.ApiFailure);
        }
        try matches.append(allocator, .{
            .event = event,
            .delivery_id = delivery_id,
            // Serialize every body before the first POST so a malformed later
            // delivery cannot leave the handler half replayed.
            .body = try std.json.Stringify.valueAlloc(allocator, payload, .{}),
        });
    }
    return .{
        .matches = try matches.toOwnedSlice(allocator),
        .saw_payload = saw_payload,
        .partial = oldest_matches and deliveries.len >= DELIVERY_WINDOW,
    };
}

fn requireLocalUrl(value: []const u8) ![]const u8 {
    const uri = std.Uri.parse(value) catch
        return fail("--url must be a full URL, for example http://localhost:3000/", .{}, error.InvalidOptions);
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return fail("--url must use http or https", .{}, error.InvalidOptions);
    }
    return value;
}

fn replay(context: *const Context) !void {
    const run_id = try context.args.requirePositional(2, "run-id");
    const handler_url = try requireLocalUrl(try context.args.require("url"));
    const agent_id = context.args.get("agent") orelse "self";
    const secret = try webhookSecret(context.allocator);
    defer {
        @memset(secret, 0);
        context.allocator.free(secret);
    }

    var response = try fetchSubscription(context, agent_id);
    defer response.deinit();
    const document = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer document.deinit();
    const root = document.value;
    const deliveries = blk: {
        const field = if (root == .object) root.object.get("deliveries") else null;
        break :blk if (field != null and field.? == .array) field.?.array.items else &[_]std.json.Value{};
    };

    var selection = try selectRun(context.allocator, deliveries, run_id);
    defer selection.deinit(context.allocator);
    if (selection.matches.len == 0) {
        if (!selection.saw_payload) {
            return fail(
                "no recorded payloads came back. Ask the owner to switch on the htpr-6124-agent-dev-loop flag for this account, and check the agent has run events switched on",
                .{},
                error.ApiNotFound,
            );
        }
        return fail("run {s} is not in this agent's last {d} recorded deliveries", .{ run_id, DELIVERY_WINDOW }, error.ApiNotFound);
    }
    if (selection.partial) {
        note("warning: run {s} reaches the oldest retained delivery, so earlier events of this run may be missing", .{run_id});
    }

    var timestamp_buffer: [24]u8 = undefined;
    const timestamp = try std.fmt.bufPrint(&timestamp_buffer, "{d}", .{std.time.timestamp()});

    var summary = try json.Object.init(context.allocator);
    defer summary.deinit();
    var results: std.ArrayListUnmanaged(u8) = .{};
    defer results.deinit(context.allocator);
    try results.append(context.allocator, '[');
    var failed = false;

    for (selection.matches, 0..) |recorded, index| {
        const signature = try signatureHeader(context.allocator, secret, timestamp, recorded.body);
        defer context.allocator.free(signature);
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "X-Hypertask-Event", .value = recorded.event },
            .{ .name = "X-Hypertask-Delivery", .value = recorded.delivery_id },
            .{ .name = "X-Hypertask-Timestamp", .value = timestamp },
            .{ .name = "X-Hypertask-Signature", .value = signature },
        };
        var status: i64 = 0;
        var error_text: ?[]const u8 = null;
        if (http.send(context.allocator, .POST, handler_url, &headers, recorded.body)) |sent| {
            var delivered = sent;
            defer delivered.deinit();
            status = @intFromEnum(delivered.status);
            if (status < 200 or status >= 300) failed = true;
        } else |err| {
            failed = true;
            error_text = @errorName(err);
        }

        if (index != 0) try results.append(context.allocator, ',');
        var entry = try json.Object.init(context.allocator);
        defer entry.deinit();
        try entry.string("deliveryId", recorded.delivery_id);
        try entry.string("event", recorded.event);
        if (error_text) |value| {
            try entry.nullValue("status");
            try entry.string("error", value);
        } else try entry.integer("status", status);
        try results.appendSlice(context.allocator, try entry.finish());
    }
    try results.append(context.allocator, ']');

    try summary.boolean("success", !failed);
    try summary.string("runId", run_id);
    try summary.boolean("partial", selection.partial);
    try summary.raw("replayed", results.items);
    try context.print(try summary.finish());
    if (failed) return error.CommandFailed;
}

// ---------------------------------------------------------------- dev

var stop_requested: std.atomic.Value(bool) = .init(false);

fn onStopSignal(_: c_int) callconv(.c) void {
    stop_requested.store(true, .seq_cst);
}

/// Guard the agent id before it becomes a file name.
fn safeStateName(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') return false;
    }
    return true;
}

fn statePath(context: *const Context, agent_id: []const u8) ![]u8 {
    if (!safeStateName(agent_id)) {
        return fail("--agent must be an agent id (letters, digits, dashes)", .{}, error.InvalidOptions);
    }
    const home = try environmentValue(context.allocator, "HOME") orelse
        return fail("HOME is not set, so the previous webhook URL cannot be saved", .{}, error.NoHome);
    defer context.allocator.free(home);
    // The tunnel log path is built from HOME and handed to a shell, so a quote
    // in HOME would end the quoting and run the rest as a command.
    if (std.mem.indexOfScalar(u8, home, '\'') != null) {
        return fail("HOME contains a quote character, which this command cannot use safely", .{}, error.InvalidOptions);
    }
    var endpoint_buffer: [16]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&endpoint_buffer, "{x}", .{std.hash.Wyhash.hash(0, context.cfg.api_url)});
    const directory = try std.fs.path.join(context.allocator, &.{ home, ".local", "state", "hypertask-agent", endpoint, "agent-dev" });
    defer context.allocator.free(directory);
    try std.fs.cwd().makePath(directory);
    return std.fmt.allocPrint(context.allocator, "{s}/{s}.json", .{ directory, agent_id });
}

const SavedState = struct {
    previous: ?[]const u8,
    installed: []const u8,
};

/// ponytail: liveness is a recorded pid, so a recycled pid can still be read as
/// a live sibling. An exclusive lock file is the upgrade if that ever bites.
fn processIsAlive(pid: i64) bool {
    if (pid <= 0) return false;
    std.posix.kill(@intCast(pid), 0) catch return false;
    return true;
}

fn writeState(allocator: std.mem.Allocator, path: []const u8, state: SavedState) !void {
    var body = try json.Object.init(allocator);
    defer body.deinit();
    if (state.previous) |value| try body.string("previous", value) else try body.nullValue("previous");
    try body.string("installed", state.installed);
    try body.integer("pid", std.posix.system.getpid());
    const temporary = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary);
    {
        var file = try std.fs.cwd().createFile(temporary, .{ .mode = 0o600, .truncate = true });
        defer file.close();
        try file.writeAll(try body.finish());
        try file.sync();
    }
    try std.fs.cwd().rename(temporary, path);
}

fn readState(allocator: std.mem.Allocator, path: []const u8) !?std.json.Parsed(std.json.Value) {
    const raw = std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024) catch return null;
    defer allocator.free(raw);
    return std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch null;
}

fn subscriptionUrl(root: std.json.Value, allocator: std.mem.Allocator) !?[]u8 {
    const subscription = if (root == .object) root.object.get("subscription") else null;
    if (subscription == null or subscription.? != .object) return null;
    const url = stringField(subscription.?, "url") orelse return null;
    return try allocator.dupe(u8, url);
}

fn currentUrl(context: *const Context, agent_id: []const u8) !?[]u8 {
    var response = try fetchSubscription(context, agent_id);
    defer response.deinit();
    const document = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer document.deinit();
    return subscriptionUrl(document.value, context.allocator);
}

fn configureUrl(context: *const Context, agent_id: []const u8, url: []const u8) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("action", "configure");
    try body.string("agent_id", agent_id);
    try body.string("url", url);
    var response = try context.fetch(.POST, "/mcp/webhooks", try body.finish());
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        try output.print(response.body);
        return error.ApiFailure;
    }
}

/// Put the saved URL back, but only while the live URL is still the one this
/// session installed. Anything else means someone changed it meanwhile, and
/// overwriting that would be the data loss this guard exists to prevent.
fn restore(context: *const Context, agent_id: []const u8, path: []const u8, installed: []const u8, previous: ?[]const u8) void {
    const live = currentUrl(context, agent_id) catch |err| {
        note("could not read the webhook back ({s}); the saved URL stays in {s}", .{ @errorName(err), path });
        return;
    };
    defer if (live) |value| context.allocator.free(value);

    if (live == null or !std.mem.eql(u8, live.?, installed)) {
        note("the webhook URL changed while this session ran, so it was left alone", .{});
        std.fs.cwd().deleteFile(path) catch {};
        return;
    }
    if (previous) |value| {
        configureUrl(context, agent_id, value) catch |err| {
            note("could not restore {s} ({s}); it is saved in {s} and the next `hypertask agent dev` retries", .{ value, @errorName(err), path });
            return;
        };
        note("restored the webhook URL to {s}", .{value});
    }
    std.fs.cwd().deleteFile(path) catch {};
}

/// A leftover state file means a previous session was killed before it could
/// put the URL back.
fn recoverStaleState(context: *const Context, agent_id: []const u8, path: []const u8) !void {
    const parsed = try readState(context.allocator, path) orelse return;
    defer parsed.deinit();
    const installed = stringField(parsed.value, "installed") orelse {
        std.fs.cwd().deleteFile(path) catch {};
        return;
    };
    const pid_field = if (parsed.value == .object) parsed.value.object.get("pid") else null;
    const pid = if (pid_field != null and pid_field.? == .integer) pid_field.?.integer else 0;
    // Another live session holds this agent's webhook. Taking it over would put
    // that session's URL back while it is still listening, and it would never
    // notice. Refuse instead of calling a healthy session a crashed one.
    if (processIsAlive(pid)) {
        return fail(
            "`hypertask agent dev` is already running for agent {s} as process {d}. Stop it first.",
            .{ agent_id, pid },
            error.CommandFailed,
        );
    }
    const previous_field = if (parsed.value == .object) parsed.value.object.get("previous") else null;
    const previous = if (previous_field != null and previous_field.? == .string) previous_field.?.string else null;
    note("a previous `hypertask agent dev` session did not shut down cleanly; restoring first", .{});
    restore(context, agent_id, path, installed, previous);
}

fn requireTunnelPath(value: []const u8) ![]const u8 {
    if (value.len == 0 or value[0] != '/') return fail("--path must start with /", .{}, error.InvalidOptions);
    for (value) |byte| {
        if (byte == '?' or byte == '#' or byte <= 0x20 or byte > 0x7e) {
            return fail("--path must be a plain path, with no query string or fragment", .{}, error.InvalidOptions);
        }
    }
    return value;
}

fn requirePublicUrl(value: []const u8) ![]const u8 {
    const trimmed = std.mem.trimRight(u8, value, "/");
    if (!std.mem.startsWith(u8, trimmed, "https://") or trimmed.len < "https://a.b".len) {
        return fail("the tunnel URL must be a public https URL", .{}, error.InvalidOptions);
    }
    return trimmed;
}

/// cloudflared prints its public hostname on stderr. Redirecting the child's
/// output to a file instead of a pipe means a long session cannot wedge on a
/// pipe nobody is draining any more.
pub fn findTunnelUrl(text: []const u8) ?[]const u8 {
    var rest = text;
    while (std.mem.indexOf(u8, rest, "https://")) |start| {
        const candidate = rest[start..];
        var end: usize = 0;
        while (end < candidate.len and candidate[end] > 0x20 and candidate[end] != '"' and candidate[end] != 0x7f) : (end += 1) {}
        const url = std.mem.trimRight(u8, candidate[0..end], "/.,");
        if (std.mem.endsWith(u8, url, ".trycloudflare.com")) return url;
        rest = candidate[if (end == 0) 1 else end..];
    }
    return null;
}

fn spawnTunnel(context: *const Context, port: i64, log_path: []const u8) !struct { child: std.process.Child, url: []u8 } {
    std.fs.cwd().deleteFile(log_path) catch {};
    const script = try std.fmt.allocPrint(
        context.allocator,
        "exec cloudflared tunnel --url http://localhost:{d} >'{s}' 2>&1",
        .{ port, log_path },
    );
    defer context.allocator.free(script);
    var child = std.process.Child.init(&.{ "sh", "-c", script }, context.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| {
        return fail("could not start a tunnel ({s}). Install cloudflared, or pass --tunnel-url with your own public https tunnel", .{@errorName(err)}, err);
    };
    errdefer _ = child.kill() catch {};

    var waited: u64 = 0;
    while (waited < TUNNEL_WAIT_MS) : (waited += TUNNEL_POLL_MS) {
        std.Thread.sleep(TUNNEL_POLL_MS * std.time.ns_per_ms);
        const log = std.fs.cwd().readFileAlloc(context.allocator, log_path, 256 * 1024) catch continue;
        defer context.allocator.free(log);
        if (findTunnelUrl(log)) |url| return .{ .child = child, .url = try context.allocator.dupe(u8, url) };
    }
    return fail("the tunnel did not report a public address within {d} seconds; see {s}", .{ TUNNEL_WAIT_MS / 1000, log_path }, error.CommandFailed);
}

fn dev(context: *const Context) !void {
    // --agent is required and never defaults to "self": a stray command in the
    // wrong shell must not be able to repoint a live agent's webhook.
    const agent_id = try context.args.require("agent");
    const port = try common.positiveInt(try context.args.require("port"), "port");
    if (port > 65535) return fail("--port must be below 65536", .{}, error.InvalidOptions);
    const tunnel_path = try requireTunnelPath(context.args.get("path") orelse "/");

    const state_path = try statePath(context, agent_id);
    defer context.allocator.free(state_path);
    try recoverStaleState(context, agent_id, state_path);

    const previous = try currentUrl(context, agent_id) orelse
        return fail("agent {s} has no webhook yet. Run `hypertask webhook configure --agent {s} --url <https url> --event run.created --event run.prompted` first: that call is the only place the webhook secret is shown.", .{ agent_id, agent_id }, error.ApiNotFound);
    defer context.allocator.free(previous);

    const log_path = try std.fmt.allocPrint(context.allocator, "{s}.log", .{state_path});
    defer context.allocator.free(log_path);

    var child: ?std.process.Child = null;
    const public = if (context.args.get("tunnel-url")) |value|
        try context.allocator.dupe(u8, try requirePublicUrl(value))
    else public_blk: {
        const started = try spawnTunnel(context, port, log_path);
        child = started.child;
        break :public_blk started.url;
    };
    defer context.allocator.free(public);
    defer if (child) |*value| {
        _ = std.posix.kill(value.id, std.posix.SIG.TERM) catch {};
        _ = value.wait() catch {};
    };

    const installed = try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ try requirePublicUrl(public), tunnel_path });
    defer context.allocator.free(installed);

    // Catch Ctrl-C before the webhook is touched, so no window exists where the
    // default signal disposition kills the process with the tunnel URL live.
    installSignalHandlers();

    // Save before changing anything, so a crash between here and the next line
    // still leaves the old URL recoverable.
    try writeState(context.allocator, state_path, .{ .previous = previous, .installed = installed });
    defer restore(context, agent_id, state_path, installed, previous);

    try configureUrl(context, agent_id, installed);

    var summary = try json.Object.init(context.allocator);
    defer summary.deinit();
    try summary.boolean("success", true);
    try summary.string("agentId", agent_id);
    try summary.string("url", installed);
    try summary.string("previousUrl", previous);
    try summary.integer("port", port);
    try context.print(try summary.finish());
    note("listening. Press Ctrl-C to put {s} back.", .{previous});

    while (!stop_requested.load(.seq_cst)) {
        std.Thread.sleep(TUNNEL_POLL_MS * std.time.ns_per_ms);
        if (child) |value| {
            const waited = std.posix.waitpid(value.id, std.posix.W.NOHANG);
            if (waited.pid == value.id) {
                child = null;
                note("the tunnel exited; putting the webhook URL back. See {s}", .{log_path});
                break;
            }
        }
    }
}

fn installSignalHandlers() void {
    var action = std.posix.Sigaction{
        .handler = .{ .handler = onStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &action, null);
    std.posix.sigaction(std.posix.SIG.TERM, &action, null);
}

// ---------------------------------------------------------------- tests

test "the signature matches the app's signWebhookBody output" {
    // Reference digest from the app's own signer:
    //   crypto.createHmac('sha256', 'whsec_test')
    //     .update('1757000000.{"event":"run.created"}').digest('hex')
    // If this drifts, every replay 401s at the SDK and the dev loop is dead.
    const signature = try signatureHeader(std.testing.allocator, "whsec_test", "1757000000", "{\"event\":\"run.created\"}");
    defer std.testing.allocator.free(signature);
    try std.testing.expectEqualStrings(
        "sha256=86a3883ccc44eebb4560975dce265a6d7d8bd303f700840de0dc3e03a146a487",
        signature,
    );
    // The timestamp is signed, so a replayed body cannot be lifted onto a
    // different one.
    const other = try signatureHeader(std.testing.allocator, "whsec_test", "1757000001", "{\"event\":\"run.created\"}");
    defer std.testing.allocator.free(other);
    try std.testing.expect(!std.mem.eql(u8, signature, other));
}

fn parseDeliveries(allocator: std.mem.Allocator, source: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, source, .{});
}

test "replay picks one run out of the delivery window, oldest first" {
    const source =
        \\[{"payload":{"runId":"r1","event":"run.stopped","deliveryId":"d3"}},
        \\ {"payload":{"runId":"r2","event":"run.created","deliveryId":"d9"}},
        \\ {"payload":{"runId":"r1","event":"run.created","deliveryId":"d1"}}]
    ;
    var parsed = try parseDeliveries(std.testing.allocator, source);
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const selection = try selectRun(arena.allocator(), parsed.value.array.items, "r1");
    try std.testing.expectEqual(@as(usize, 2), selection.matches.len);
    try std.testing.expectEqualStrings("d1", selection.matches[0].delivery_id);
    try std.testing.expectEqualStrings("run.created", selection.matches[0].event);
    try std.testing.expectEqualStrings("d3", selection.matches[1].delivery_id);
    try std.testing.expect(selection.saw_payload);
    // Three deliveries is under the window, so nothing aged out.
    try std.testing.expect(!selection.partial);
}

test "a run touching the oldest retained delivery is reported as partial" {
    var buffer: std.ArrayListUnmanaged(u8) = .{};
    defer buffer.deinit(std.testing.allocator);
    try buffer.appendSlice(std.testing.allocator, "[");
    for (0..DELIVERY_WINDOW) |index| {
        if (index != 0) try buffer.appendSlice(std.testing.allocator, ",");
        try buffer.writer(std.testing.allocator).print(
            "{{\"payload\":{{\"runId\":\"r1\",\"event\":\"run.prompted\",\"deliveryId\":\"d{d}\"}}}}",
            .{index},
        );
    }
    try buffer.appendSlice(std.testing.allocator, "]");

    var parsed = try parseDeliveries(std.testing.allocator, buffer.items);
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try selectRun(arena.allocator(), parsed.value.array.items, "r1");
    try std.testing.expect(selection.partial);
}

test "deliveries without payloads are reported apart from an unknown run" {
    var parsed = try parseDeliveries(std.testing.allocator, "[{\"id\":\"d1\",\"event\":\"comment.created\"}]");
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const selection = try selectRun(arena.allocator(), parsed.value.array.items, "r1");
    try std.testing.expectEqual(@as(usize, 0), selection.matches.len);
    try std.testing.expect(!selection.saw_payload);
}

test "a recorded delivery cannot smuggle a header break into the replay" {
    var parsed = try parseDeliveries(
        std.testing.allocator,
        "[{\"payload\":{\"runId\":\"r1\",\"event\":\"run.created\\r\\nX-Bad: 1\",\"deliveryId\":\"d1\"}}]",
    );
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ApiFailure, selectRun(arena.allocator(), parsed.value.array.items, "r1"));
}

test "the tunnel address is read out of cloudflared's own output" {
    const log =
        \\2026-09-06T13:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
        \\2026-09-06T13:00:02Z INF +----------------------------------------+
        \\2026-09-06T13:00:02Z INF |  https://odd-fox-runs-here.trycloudflare.com  |
        \\2026-09-06T13:00:02Z INF +----------------------------------------+
    ;
    try std.testing.expectEqualStrings("https://odd-fox-runs-here.trycloudflare.com", findTunnelUrl(log).?);
    try std.testing.expect(findTunnelUrl("INF connecting to https://api.cloudflare.com/x") == null);
    try std.testing.expect(findTunnelUrl("") == null);
}

test "dev rejects paths and tunnel URLs that are not what they claim" {
    try std.testing.expectError(error.InvalidOptions, requireTunnelPath("webhook"));
    try std.testing.expectError(error.InvalidOptions, requireTunnelPath("/hook?token=1"));
    try std.testing.expectError(error.InvalidOptions, requireTunnelPath("/hook#f"));
    try std.testing.expectEqualStrings("/hook", try requireTunnelPath("/hook"));
    try std.testing.expectError(error.InvalidOptions, requirePublicUrl("http://localhost:3000"));
    try std.testing.expectEqualStrings("https://a.trycloudflare.com", try requirePublicUrl("https://a.trycloudflare.com/"));
    try std.testing.expectError(error.InvalidOptions, requireLocalUrl("localhost:3000"));
    try std.testing.expectError(error.InvalidOptions, requireLocalUrl("file:///etc/passwd"));
}

test "an agent id used as a file name cannot escape the state directory" {
    try std.testing.expect(!safeStateName("../../etc/passwd"));
    try std.testing.expect(!safeStateName("self"[0..0]));
    try std.testing.expect(safeStateName("95a19a8a-5c0b-4d65-93a6-71b8b283b536"));
}

test "a state file left by a live process is not treated as a crash" {
    // Recovery repoints the webhook. Getting this wrong steals the URL from a
    // session that is still listening on it.
    try std.testing.expect(processIsAlive(std.posix.system.getpid()));
    try std.testing.expect(!processIsAlive(0));
    try std.testing.expect(!processIsAlive(-1));
}
