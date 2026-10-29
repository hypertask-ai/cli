const std = @import("std");
const Context = @import("../command_context.zig").Context;
const config = @import("../config.zig");
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");

const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const encoder = std.base64.url_safe_no_pad.Encoder;

pub fn validCode(code: []const u8) bool {
    if (code.len != 9 or code[4] != '-') return false;
    for (code, 0..) |byte, index| {
        if (index == 4) continue;
        if (std.mem.indexOfScalar(u8, alphabet, byte) == null) return false;
    }
    return true;
}

pub fn officialOrigin(url: []const u8) bool {
    return std.mem.eql(u8, url, config.default_api_url) or
        std.mem.eql(u8, url, "https://app.hypertask.ai/api");
}

fn secret() [43]u8 {
    var bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    var result: [43]u8 = undefined;
    _ = encoder.encode(&result, &bytes);
    return result;
}

fn challenge(verifier: []const u8) [43]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var result: [43]u8 = undefined;
    _ = encoder.encode(&result, &digest);
    return result;
}

const RequestJob = struct {
    const State = enum(u8) { running, completed, abandoned };
    arena: std.heap.ArenaAllocator,
    url: []const u8,
    method: std.http.Method,
    body: ?[]const u8,
    token: ?[]const u8,
    response: ?http.Response = null,
    failure: ?anyerror = null,
    done: std.Thread.Semaphore = .{},
    state: std.atomic.Value(State) = .init(.running),

    fn create(url: []const u8, method: std.http.Method, body: ?[]const u8, token: ?[]const u8) !*RequestJob {
        const job = try std.heap.page_allocator.create(RequestJob);
        job.* = .{ .arena = .init(std.heap.page_allocator), .url = "", .method = method, .body = null, .token = null };
        errdefer job.destroy();
        const allocator = job.arena.allocator();
        job.url = try allocator.dupe(u8, url);
        job.body = if (body) |value| try allocator.dupe(u8, value) else null;
        job.token = if (token) |value| try allocator.dupe(u8, value) else null;
        return job;
    }

    fn destroy(job: *RequestJob) void {
        job.arena.deinit();
        std.heap.page_allocator.destroy(job);
    }

    fn perform(job: *RequestJob) void {
        const allocator = job.arena.allocator();
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        var headers: [3]std.http.Header = undefined;
        headers[0] = .{ .name = "Content-Type", .value = "application/json" };
        headers[1] = .{ .name = "User-Agent", .value = "hypertask-device-login" };
        var count: usize = 2;
        if (job.token) |token| {
            const authorization = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch |err| {
                job.failure = err;
                return;
            };
            headers[2] = .{ .name = "Authorization", .value = authorization };
            count = 3;
        }
        job.response = http.send(&client, allocator, job.method, job.url, headers[0..count], job.body) catch |err| {
            job.failure = err;
            return;
        };
    }

    fn run(job: *RequestJob) void {
        job.perform();
        if (job.state.swap(.completed, .acq_rel) == .abandoned) {
            job.destroy();
            return;
        }
        job.done.post();
    }
};

fn boundedRequest(allocator: std.mem.Allocator, url: []const u8, method: std.http.Method, body: ?[]const u8, token: ?[]const u8, timeout: u64) !http.Response {
    if (timeout == 0) return error.DeviceLoginRequestTimeout;
    const job = try RequestJob.create(url, method, body, token);
    const worker = std.Thread.spawn(.{}, RequestJob.run, .{job}) catch |err| {
        job.destroy();
        return err;
    };
    job.done.timedWait(timeout) catch {
        if (job.state.swap(.abandoned, .acq_rel) == .running) {
            worker.detach();
            return error.DeviceLoginRequestTimeout;
        }
    };
    worker.join();
    defer job.destroy();
    if (job.failure) |err| return err;
    const response = job.response orelse return error.DeviceLoginUnavailable;
    return .{ .allocator = allocator, .status = response.status, .body = try allocator.dupe(u8, response.body) };
}

fn post(context: *const Context, path: []const u8, body: []const u8, timeout: u64) !http.Response {
    if (context.request_recorder) |recorder| return recorder.fetch(.POST, path, body);
    const url = try std.fmt.allocPrint(context.allocator, "{s}{s}", .{ context.cfg.api_url, path });
    defer context.allocator.free(url);
    return boundedRequest(context.allocator, url, .POST, body, null, timeout);
}

pub fn acknowledge(context: *const Context, token: []const u8) !void {
    for (0..3) |_| {
        var response = request: {
            if (context.request_recorder) |recorder| break :request recorder.fetch(.GET, "/mcp/hello", null) catch {
                wait(context, 1);
                continue;
            };
            const url = try std.fmt.allocPrint(context.allocator, "{s}/mcp/hello", .{context.cfg.api_url});
            defer context.allocator.free(url);
            break :request boundedRequest(context.allocator, url, .GET, null, token, 8 * std.time.ns_per_s) catch {
                wait(context, 1);
                continue;
            };
        };
        defer response.deinit();
        if (response.isSuccess()) {
            const parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch {
                wait(context, 1);
                continue;
            };
            defer parsed.deinit();
            const success = if (parsed.value == .object) parsed.value.object.get("success") else null;
            const user = json.objectField(parsed.value, "user");
            if (success != null and success.? == .bool and success.?.bool and user != null) {
                const user_id = json.integerField(user.?, "id", false) orelse 0;
                if (user_id > 0) return;
            }
        }
        wait(context, 1);
    }
    return error.DeviceLoginSavedNotConnected;
}

fn wait(context: *const Context, seconds: u64) void {
    if (context.request_recorder == null) std.Thread.sleep(seconds * std.time.ns_per_s);
}

fn retryable(document: std.json.Value) bool {
    const code = json.stringField(document, "error") orelse return false;
    return std.mem.eql(u8, code, "authorization_pending") or
        std.mem.eql(u8, code, "slow_down") or
        std.mem.eql(u8, code, "temporarily_unavailable");
}

fn rejection(document: std.json.Value) anyerror {
    const code = json.stringField(document, "error") orelse return error.DeviceLoginUnavailable;
    if (std.mem.eql(u8, code, "expired_token")) return error.DeviceLoginExpired;
    if (std.mem.eql(u8, code, "access_denied")) return error.DeviceLoginDenied;
    return error.DeviceLoginRejected;
}

pub fn managedAgentCredential(allocator: std.mem.Allocator, token: []const u8) !bool {
    if (token.len > 16 * 1024) return false;
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return false;
    const payload = parts.next() orelse return false;
    _ = parts.next() orelse return false;
    if (parts.next() != null) return false;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(payload) catch return false;
    const decoded = try allocator.alloc(u8, size);
    defer allocator.free(decoded);
    decoder.decode(decoded, payload) catch return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, decoded, .{}) catch return false;
    defer parsed.deinit();
    const agent_id = json.stringField(parsed.value, "agentId") orelse return false;
    return agent_id.len > 0;
}

pub fn login(context: *const Context, code: []const u8) ![]u8 {
    if (!validCode(code)) return output.invalidOptions("Use the five-minute code shown at https://app.hypertask.ai/login/agent");
    if (context.args.has("token")) return output.invalidOptions("Use --code or --token, not both.");
    if (!officialOrigin(context.cfg.api_url)) return output.invalidOptions("Code login requires the official HTTPS API.");
    const verifier = secret();
    const claimant = secret();
    const proof = challenge(&verifier);
    var claim = try json.Object.init(context.allocator);
    defer claim.deinit();
    try claim.string("code", code);
    try claim.string("claimant", &claimant);
    try claim.string("challenge", &proof);
    try claim.string("verifier", &verifier);
    try claim.string("clientName", "Hypertask CLI");
    const claim_body = try claim.finish();
    var timer = try std.time.Timer.start();
    const deadline = 300 * std.time.ns_per_s;
    var interval: u64 = 5;
    var flow_id: ?[]u8 = null;
    defer if (flow_id) |id| context.allocator.free(id);
    var attempts: usize = 0;
    while (timer.read() < deadline and attempts < 60) : (attempts += 1) {
        var response = post(context, "/cli/device/claim", claim_body, @min(deadline -| timer.read(), 8 * std.time.ns_per_s)) catch {
            wait(context, interval);
            continue;
        };
        defer response.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.DeviceLoginUnavailable;
        defer parsed.deinit();
        if (response.isSuccess()) {
            const id = json.stringField(parsed.value, "id") orelse return error.DeviceLoginUnavailable;
            if (id.len != 36) return error.DeviceLoginUnavailable;
            flow_id = try context.allocator.dupe(u8, id);
            break;
        }
        if (!retryable(parsed.value)) return rejection(parsed.value);
        interval = @min(interval + 5, 30);
        wait(context, interval);
    }
    const id = flow_id orelse return error.DeviceLoginExpired;
    if (context.request_recorder == null) std.debug.print("Approve this agent in your browser.\n", .{});
    var poll = try json.Object.init(context.allocator);
    defer poll.deinit();
    try poll.string("id", id);
    try poll.string("claimant", &claimant);
    try poll.string("verifier", &verifier);
    const poll_body = try poll.finish();
    attempts = 0;
    while (timer.read() < deadline and attempts < 60) : (attempts += 1) {
        var response = post(context, "/cli/device/token", poll_body, @min(deadline -| timer.read(), 8 * std.time.ns_per_s)) catch {
            wait(context, 1);
            continue;
        };
        defer response.deinit();
        const parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.DeviceLoginUnavailable;
        defer parsed.deinit();
        if (response.isSuccess()) {
            const token = json.stringField(parsed.value, "token") orelse return error.DeviceLoginUnavailable;
            if (!try managedAgentCredential(context.allocator, token)) return error.DeviceLoginRejected;
            return context.allocator.dupe(u8, token);
        }
        if (!retryable(parsed.value)) return rejection(parsed.value);
        if (response.status == .too_many_requests) interval = @min(interval + 5, 30);
        wait(context, if (response.status == .service_unavailable) 1 else interval);
    }
    return error.DeviceLoginExpired;
}

test "device login validates display codes and official origins" {
    try std.testing.expect(validCode("ABCD-1234"));
    for ([_][]const u8{ "ABCD1234", "abcd-1234", "ABCI-1234", "ABCD-12U4", "ABCD-12345" }) |code| try std.testing.expect(!validCode(code));
    try std.testing.expect(officialOrigin("https://api.hypertask.ai/api"));
    try std.testing.expect(officialOrigin("https://app.hypertask.ai/api"));
    for ([_][]const u8{ "http://api.hypertask.ai/api", "https://evil.example/api", "https://app.hypertask.ai.evil.example/api", "https://app.hypertask.ai:443/api" }) |url| try std.testing.expect(!officialOrigin(url));
}

test "device login verifier uses S256 and rejects human credentials" {
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"));
    try std.testing.expect(!try managedAgentCredential(std.testing.allocator, "not-a-token"));
    try std.testing.expect(!try managedAgentCredential(std.testing.allocator, "header.eyJ1c2VySWQiOjQyfQ.signature"));
    try std.testing.expect(try managedAgentCredential(std.testing.allocator, "header.eyJhZ2VudElkIjoiYWdlbnQtMSJ9.signature"));
}

fn testLogin(argv: []const []const u8, api_url: []const u8, responses: []const []const u8, statuses: []const std.http.Status, expected_error: ?anyerror, count: usize) !void {
    const args = @import("../args.zig");
    const recorder_type = @import("../command_context.zig").RequestRecorder;
    const allocator = std.testing.allocator;
    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit();
    try @import("../option_validate.zig").rejectUnknownOptions(allocator, &parsed);
    try parsed.requireValues();
    var cfg = config.Config{ .allocator = allocator, .api_url = api_url };
    defer cfg.deinit();
    var recorder = recorder_type.init(allocator);
    defer recorder.deinit();
    recorder.responses = responses;
    recorder.response_statuses = statuses;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = Context{ .client = &client, .allocator = allocator, .args = &parsed, .cfg = &cfg, .json = true, .request_recorder = &recorder };
    const result = login(&context, parsed.get("code") orelse "");
    if (expected_error) |err| {
        try std.testing.expectError(err, result);
    } else {
        const issued = try result;
        defer allocator.free(issued);
        try std.testing.expectEqualStrings("header.eyJhZ2VudElkIjoiYWdlbnQtMSJ9.signature", issued);
        try std.testing.expectEqualStrings("/cli/device/token", recorder.path.?);
        const body = try std.json.parseFromSlice(std.json.Value, allocator, recorder.body.?, .{});
        defer body.deinit();
        try std.testing.expectEqual(@as(usize, 43), json.stringField(body.value, "verifier").?.len);
        try std.testing.expectEqual(@as(usize, 43), json.stringField(body.value, "claimant").?.len);
        try std.testing.expect(!std.mem.eql(u8, json.stringField(body.value, "verifier").?, json.stringField(body.value, "claimant").?));
    }
    try std.testing.expectEqual(count, recorder.responses_index);
    try std.testing.expectEqualStrings("", cfg.token);
}

test "device login accepts the code parser without any saved token and polls approval" {
    try testLogin(&.{ "login", "--code", "ABCD-1234" }, config.default_api_url, &.{
        "{\"id\":\"12345678-1234-4234-8234-123456789012\"}",
        "{\"error\":\"authorization_pending\"}",
        "{\"token\":\"header.eyJhZ2VudElkIjoiYWdlbnQtMSJ9.signature\"}",
    }, &.{ .ok, .bad_request, .ok }, null, 3);
}

test "device login refuses human tokens, denial, expired codes and off-origin APIs" {
    const claimed = "{\"id\":\"12345678-1234-4234-8234-123456789012\"}";
    try testLogin(&.{ "login", "--code", "ABCD-1234" }, config.default_api_url, &.{ claimed, "{\"token\":\"header.eyJ1c2VySWQiOjQyfQ.signature\"}" }, &.{ .ok, .ok }, error.DeviceLoginRejected, 2);
    try testLogin(&.{ "login", "--code", "ABCD-1234" }, config.default_api_url, &.{ claimed, "{\"error\":\"access_denied\"}" }, &.{ .ok, .forbidden }, error.DeviceLoginDenied, 2);
    try testLogin(&.{ "login", "--code", "ABCD-1234" }, config.default_api_url, &.{"{\"error\":\"expired_token\"}"}, &.{.bad_request}, error.DeviceLoginExpired, 1);
    try testLogin(&.{ "login", "--code", "ABCD-1234" }, "https://evil.example/api", &.{}, &.{}, error.InvalidOptions, 0);
    try testLogin(&.{ "login", "--code", "ABCD-1234", "--token", "fake" }, config.default_api_url, &.{}, &.{}, error.InvalidOptions, 0);
    try testLogin(&.{ "login", "--code", "bad-code" }, config.default_api_url, &.{}, &.{}, error.InvalidOptions, 0);
}

test "device login bounds a stalled network response without borrowing caller memory" {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();
    const Peer = struct {
        fn run(listener: *std.net.Server) void {
            const peer = listener.accept() catch return;
            defer peer.stream.close();
            std.Thread.sleep(750 * std.time.ns_per_ms);
        }
    };
    const peer = try std.Thread.spawn(.{}, Peer.run, .{&server});
    defer peer.join();
    const url = try std.fmt.allocPrint(std.testing.allocator, "http://127.0.0.1:{d}/fixture", .{server.listen_address.getPort()});
    defer std.testing.allocator.free(url);
    var timer = try std.time.Timer.start();
    try std.testing.expectError(error.DeviceLoginRequestTimeout, boundedRequest(std.testing.allocator, url, .POST, "{}", null, 50 * std.time.ns_per_ms));
    try std.testing.expect(timer.read() < 500 * std.time.ns_per_ms);
}

test "device login recovers uncertain delivery after slowdown and requires authenticated acknowledgment" {
    const args = @import("../args.zig");
    const recorder_type = @import("../command_context.zig").RequestRecorder;
    const allocator = std.testing.allocator;
    var parsed = try args.parse(allocator, &.{ "login", "--code", "ABCD-1234" });
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = allocator };
    defer cfg.deinit();
    var recorder = recorder_type.init(allocator);
    defer recorder.deinit();
    recorder.responses = &.{
        "{\"id\":\"12345678-1234-4234-8234-123456789012\"}",
        "{\"error\":\"slow_down\"}",
        "{\"error\":\"slow_down\"}",
        "{\"error\":\"slow_down\"}",
        "{\"error\":\"slow_down\"}",
        "{\"error\":\"slow_down\"}",
        "lost delivery",
        "{\"token\":\"header.eyJhZ2VudElkIjoiYWdlbnQtMSJ9.signature\"}",
        "<html>login</html>",
        "{\"success\":false,\"user\":{\"id\":42}}",
        "{\"success\":true,\"user\":{\"id\":42},\"boards\":[]}",
    };
    recorder.response_statuses = &.{ .ok, .too_many_requests, .too_many_requests, .too_many_requests, .too_many_requests, .too_many_requests, .ok, .ok, .ok, .ok, .ok };
    recorder.response_errors = &.{ null, null, null, null, null, null, error.ConnectionResetByPeer };
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = Context{ .client = &client, .allocator = allocator, .args = &parsed, .cfg = &cfg, .json = true, .request_recorder = &recorder };
    const issued = try login(&context, "ABCD-1234");
    defer allocator.free(issued);
    try acknowledge(&context, issued);
    try std.testing.expectEqual(@as(usize, 11), recorder.responses_index);
    try std.testing.expectEqualStrings("/mcp/hello", recorder.path.?);
    recorder.responses = &.{};
    recorder.response_statuses = &.{};
    try std.testing.expectError(error.DeviceLoginSavedNotConnected, acknowledge(&context, issued));
}
