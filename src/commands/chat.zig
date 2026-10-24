const std = @import("std");
const builtin = @import("builtin");
const common = @import("../command_context.zig");
const Context = common.Context;
const config = @import("../config.zig");
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");
const state = @import("../state_store.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "reply")) return reply(context);
    if (!std.mem.eql(u8, subcommand, "listen")) return error.UnknownCommand;
    const seconds = try interval(context.args.get("interval"));
    try context.requireAuth();
    if (comptime builtin.os.tag == .windows) return error.UnsupportedPlatform;

    // State is atomically saved before output. Immediate signal exit also stops
    // a stalled HTTP read; the OS releases the file lock without a noisy error.
    const action = std.posix.Sigaction{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
    var previous: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.INT, &action, &previous);
    defer std.posix.sigaction(std.posix.SIG.INT, &previous, null);
    var waiter = Waiter{};
    try listenLoop(context, null, seconds, context.args.has("once"), std.fs.File.stdout(), &waiter);
}

fn interrupt(_: i32) callconv(.c) void {
    std.posix.exit(0);
}

const Waiter = struct {
    fn wait(_: *Waiter, seconds: u64) bool {
        std.Thread.sleep(seconds * std.time.ns_per_s);
        return true;
    }
};

fn interval(raw: ?[]const u8) !u64 {
    const seconds = std.fmt.parseInt(u64, raw orelse "5", 10) catch return error.InvalidInterval;
    if (seconds < 1 or seconds > 60) return error.InvalidInterval;
    return seconds;
}

fn checkedFetch(context: *const Context, method: std.http.Method, path: []const u8, body: ?[]const u8) !http.Response {
    try context.requireAuth();
    // Unit tests must supply the HTTP recorder; never fall through to live HTTP.
    var response = if (comptime builtin.is_test)
        try (context.request_recorder orelse return error.UnstubbedChatRequest).fetch(method, path, body)
    else
        try context.fetchRaw(method, path, body);
    errdefer response.deinit();
    switch (@intFromEnum(response.status)) {
        200...299 => {},
        401, 403 => return error.ChatAgentTokenRequired,
        404 => return error.ChatEndpointUnavailable,
        400, 402, 405...428, 430...499 => return error.ChatRequestRejected,
        else => return error.ChatPollFailed,
    }
    if (output.responseReportsFailure(context.allocator, response.body)) return error.ChatPollFailed;
    return response;
}

fn listenLoop(context: *const Context, directory_override: ?[]const u8, seconds: u64, once: bool, writer: anytype, waiter: anytype) !void {
    var owned_directory: ?[]u8 = null;
    defer if (owned_directory) |directory| std.heap.page_allocator.free(directory);
    var delay = seconds;
    while (true) {
        // main uses an arena for short-lived commands; a listener must reclaim
        // each response and parsed document instead of growing that arena forever.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var cycle = context.*;
        cycle.allocator = arena.allocator();
        const result: anyerror!void = cycle: {
            const directory = directory_override orelse owned_directory orelse resolve: {
                const resolved = stateDirectory(&cycle) catch |err| break :cycle err;
                owned_directory = std.heap.page_allocator.dupe(u8, resolved) catch |err| break :cycle err;
                break :resolve owned_directory.?;
            };
            break :cycle poll(&cycle, directory, writer);
        };
        result catch |err| {
            if (once) return err;
            switch (err) {
                error.ChatAgentTokenRequired,
                error.ChatEndpointUnavailable,
                error.ChatRequestRejected,
                error.AccessDenied,
                error.NoSpaceLeft,
                error.BrokenPipe,
                error.DiskQuota,
                error.NoHome,
                => return err,
                else => {},
            }
            delay = @min(delay * 2, 60);
            std.debug.print("hypertask chat listen: {s}; retrying in {d}s\n", .{ @errorName(err), delay });
            if (!waiter.wait(delay)) return;
            continue;
        };
        if (once) return;
        delay = seconds;
        if (!waiter.wait(delay)) return;
    }
}

fn stateDirectory(context: *const Context) ![]u8 {
    var response = try checkedFetch(context, .GET, "/mcp/user/context", null);
    defer response.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const agent = if (parsed.value == .object) parsed.value.object.get("connected_agent") else null;
    const id = json.stringField(agent orelse return error.ChatAgentTokenRequired, "id") orelse return error.ChatAgentTokenRequired;
    if (id.len == 0) return error.ChatAgentTokenRequired;
    const config_path = try config.configPath(context.allocator);
    defer context.allocator.free(config_path);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(context.cfg.api_url);
    hash.update("\x00");
    hash.update(id);
    const digest = hash.finalResult();
    const scope = std.fmt.bytesToHex(digest, .lower);
    return std.fs.path.join(context.allocator, &.{ std.fs.path.dirname(config_path).?, "chat", &scope });
}

fn heartbeat(context: *const Context) !void {
    // Ordinary agent tokens cannot use the managed runtime's generation/sequence
    // heartbeat. The chat endpoint must update this token's Agent.heartbeatAt.
    var response = try checkedFetch(context, .POST, "/mcp/chat/heartbeat", "{}");
    defer response.deinit();
}

fn poll(context: *const Context, directory: []const u8, writer: anytype) !void {
    try heartbeat(context);
    try state.ensureStateDirectory(directory);
    const lock_path = try std.fs.path.join(context.allocator, &.{ directory, "listen.lock" });
    defer context.allocator.free(lock_path);
    var lock = try state.acquireFileLock(lock_path);
    defer state.releaseStateLock(&lock);
    const seen_path = try std.fs.path.join(context.allocator, &.{ directory, "seen" });
    defer context.allocator.free(seen_path);
    var seen = try state.readLines(context.allocator, seen_path);
    defer state.deinitLineSet(context.allocator, &seen);
    var response = try checkedFetch(context, .GET, "/mcp/chat/pending", null);
    defer response.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const messages = json.arrayField(parsed.value, "messages") orelse return error.InvalidResponse;
    var blocks: std.ArrayListUnmanaged(u8) = .{};
    defer blocks.deinit(context.allocator);
    for (messages) |message| {
        const id = json.stringField(message, "id") orelse return error.InvalidResponse;
        const chat_id = json.stringField(message, "sessionId") orelse return error.InvalidResponse;
        const text = json.stringField(message, "text") orelse return error.InvalidResponse;
        if (id.len == 0 or chat_id.len == 0) return error.InvalidResponse;
        // Encode identifiers so unusual server IDs cannot inject state lines.
        const key = try std.json.Stringify.valueAlloc(context.allocator, .{ chat_id, id }, .{});
        defer context.allocator.free(key);
        if (seen.contains(key)) continue;
        try state.putLine(context.allocator, &seen, key);
        try blocks.writer(context.allocator).print("Chat: {s}\nSender: {s}\n{s}\n\n", .{
            chat_id, json.stringField(message, "userName") orelse "Hypertask user", text,
        });
    }
    if (blocks.items.len == 0) return;
    // At-most-once stdout, including restarts. A crash between save and write
    // can omit a block, but can never replay one; pending already claims delivery.
    try state.writeLineSet(context.allocator, seen_path, &seen);
    try writer.writeAll(blocks.items);
}

fn reply(context: *const Context) !void {
    const chat_id = try context.args.requirePositional(2, "chat-id");
    if (chat_id.len == 0) return error.MissingArgument;
    if (std.mem.eql(u8, chat_id, ".") or std.mem.eql(u8, chat_id, "..")) return error.InvalidChatId;
    const text = std.mem.trim(u8, try context.args.require("text"), " \t\r\n");
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(text)) return error.InvalidChatText;
    // The app limits JavaScript UTF-16 code units, not UTF-8 bytes.
    var units: usize = 0;
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |point| units += if (point > 0xffff) @as(usize, 2) else 1;
    if (units > 8000) return error.InvalidChatText;
    var encoded_id: std.ArrayListUnmanaged(u8) = .{};
    defer encoded_id.deinit(context.allocator);
    try query.encode(&encoded_id, context.allocator, chat_id);
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/chat/sessions/{s}/messages", .{encoded_id.items});
    defer context.allocator.free(path);
    var response = try checkedFetch(context, .GET, path, null);
    defer response.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const messages = json.arrayField(parsed.value, "messages") orelse return error.InvalidResponse;
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const role = json.stringField(messages[index], "role") orelse continue;
        if (!std.mem.eql(u8, role, "human")) continue;
        const message_id = json.stringField(messages[index], "id") orelse return error.InvalidResponse;
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("text", text);
        try body.string("replyToMessageId", message_id);
        var posted = try checkedFetch(context, .POST, path, try body.finish());
        defer posted.deinit();
        return context.finish(&posted);
    }
    return error.NoChatMessageToReplyTo;
}

const TestContext = struct {
    arena: *std.heap.ArenaAllocator,
    parsed: @import("../args.zig").Parsed,
    cfg: config.Config,
    recorder: common.RequestRecorder,
    client: std.http.Client,

    fn init(argv: []const []const u8) !TestContext {
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer {
            arena.deinit();
            std.testing.allocator.destroy(arena);
        }
        const allocator = arena.allocator();
        return .{
            .arena = arena,
            .parsed = try @import("../args.zig").parse(allocator, argv),
            .cfg = .{ .allocator = allocator, .token = "test-token" },
            .recorder = common.RequestRecorder.init(allocator),
            .client = .{ .allocator = allocator },
        };
    }

    fn context(self: *TestContext) Context {
        return .{ .allocator = self.arena.allocator(), .args = &self.parsed, .cfg = &self.cfg, .client = &self.client, .request_recorder = &self.recorder, .json = true };
    }

    fn deinit(self: *TestContext) void {
        self.client.deinit();
        self.arena.deinit();
        std.testing.allocator.destroy(self.arena);
    }
};

const inbox_fixture =
    \\{"success":true,"messages":[
    \\{"id":"m1","sessionId":"chat-1","text":"Hello\nthere","userName":"Valentin"},
    \\{"id":"m1","sessionId":"chat-1","text":"Hello\nthere","userName":"Valentin"},
    \\{"id":"m2","sessionId":"chat-2","text":"Another chat","userName":null}]}
;

test "chat prints new messages once and skips already-seen across restarts" {
    var fixture = try TestContext.init(&.{ "chat", "listen", "--once" });
    defer fixture.deinit();
    var context = fixture.context();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(context.allocator, ".");
    var blocks: std.ArrayListUnmanaged(u8) = .{};
    defer blocks.deinit(std.testing.allocator);
    fixture.recorder.responses = &.{ "{}", inbox_fixture };
    try poll(&context, directory, blocks.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("Chat: chat-1\nSender: Valentin\nHello\nthere\n\nChat: chat-2\nSender: Hypertask user\nAnother chat\n\n", blocks.items);
    try std.testing.expectEqual(@as(usize, 2), fixture.recorder.responses_index);
    try std.testing.expectEqualStrings("/mcp/chat/pending", fixture.recorder.path.?);
    // A new Context and fresh in-memory state simulate a process restart.
    var restarted = try TestContext.init(&.{ "chat", "listen", "--once" });
    defer restarted.deinit();
    var next_context = restarted.context();
    restarted.recorder.responses = &.{ "{}", inbox_fixture };
    var duplicate: std.ArrayListUnmanaged(u8) = .{};
    defer duplicate.deinit(std.testing.allocator);
    try poll(&next_context, directory, duplicate.writer(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), duplicate.items.len);
    const persisted = try tmp.dir.readFileAlloc(context.allocator, "seen", 4096);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "m1") != null);
    try std.testing.expect(std.mem.indexOf(u8, persisted, "Hello") == null);
}

test "chat heartbeat uses the agent chat freshness endpoint" {
    var fixture = try TestContext.init(&.{ "chat", "listen", "--once" });
    defer fixture.deinit();
    var context = fixture.context();
    try heartbeat(&context);
    try std.testing.expectEqual(std.http.Method.POST, fixture.recorder.method.?);
    try std.testing.expectEqualStrings("/mcp/chat/heartbeat", fixture.recorder.path.?);
    try std.testing.expectEqualStrings("{}", fixture.recorder.body.?);
}

test "chat reply posts text and latest human message ID to the right chat" {
    var fixture = try TestContext.init(&.{ "chat", "reply", "chat/one?", "--text", "Reply \"now\"\nnext" });
    defer fixture.deinit();
    var context = fixture.context();
    fixture.recorder.responses = &.{
        "{\"messages\":[{\"id\":\"old\",\"role\":\"human\"},{\"id\":\"new\",\"role\":\"human\"},{\"id\":\"bot\",\"role\":\"assistant\"}]}",
        "{\"success\":true}",
    };
    try reply(&context);
    try std.testing.expectEqual(@as(usize, 2), fixture.recorder.responses_index);
    try std.testing.expectEqual(std.http.Method.POST, fixture.recorder.method.?);
    try std.testing.expectEqualStrings("/mcp/chat/sessions/chat%2Fone%3F/messages", fixture.recorder.path.?);
    try std.testing.expectEqualStrings("{\"text\":\"Reply \\\"now\\\"\\nnext\",\"replyToMessageId\":\"new\"}", fixture.recorder.body.?);
}

const TestWaiter = struct {
    delays: [8]u64 = @splat(0),
    count: usize = 0,
    stop_after: usize = 3,
    recover_after: usize = 2,
    recorder: *common.RequestRecorder,

    fn wait(self: *TestWaiter, seconds: u64) bool {
        self.delays[self.count] = seconds;
        self.count += 1;
        if (self.count == self.recover_after) {
            self.recorder.response_status = .ok;
            self.recorder.fetch_error = null;
            self.recorder.responses = &.{ "{}", "{\"messages\":[]}" };
            self.recorder.responses_index = 0;
        }
        return self.count < self.stop_after;
    }
};

test "chat listen backs off on 5xx and resets after recovery" {
    var fixture = try TestContext.init(&.{ "chat", "listen" });
    defer fixture.deinit();
    var context = fixture.context();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(context.allocator, ".");
    var blocks: std.ArrayListUnmanaged(u8) = .{};
    defer blocks.deinit(std.testing.allocator);
    fixture.recorder.response_status = .service_unavailable;
    var waiter = TestWaiter{ .recorder = &fixture.recorder };
    try listenLoop(&context, directory, 5, false, blocks.writer(std.testing.allocator), &waiter);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 5 }, waiter.delays[0..waiter.count]);
    try std.testing.expectEqual(@as(usize, 0), blocks.items.len);
}

test "chat listen caps backoff and retries transport errors" {
    var fixture = try TestContext.init(&.{ "chat", "listen" });
    defer fixture.deinit();
    var context = fixture.context();
    fixture.recorder.fetch_error = error.ConnectionResetByPeer;
    var blocks: std.ArrayListUnmanaged(u8) = .{};
    defer blocks.deinit(std.testing.allocator);
    var waiter = TestWaiter{ .recorder = &fixture.recorder, .recover_after = 8 };
    try listenLoop(&context, "unused", 40, false, blocks.writer(std.testing.allocator), &waiter);
    try std.testing.expectEqualSlices(u64, &.{ 60, 60, 60 }, waiter.delays[0..waiter.count]);
}

test "chat once sends heartbeat and polls once without waiting and propagates errors" {
    var fixture = try TestContext.init(&.{ "chat", "listen", "--once" });
    defer fixture.deinit();
    var context = fixture.context();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(context.allocator, ".");
    var blocks: std.ArrayListUnmanaged(u8) = .{};
    defer blocks.deinit(std.testing.allocator);
    var waiter = TestWaiter{ .recorder = &fixture.recorder };
    fixture.recorder.responses = &.{ "{}", inbox_fixture };
    try listenLoop(&context, directory, 5, true, blocks.writer(std.testing.allocator), &waiter);
    try std.testing.expectEqual(@as(usize, 0), waiter.count);
    try std.testing.expectEqual(@as(usize, 2), fixture.recorder.responses_index);
    fixture.recorder.response_status = .internal_server_error;
    try std.testing.expectError(error.ChatPollFailed, listenLoop(&context, directory, 5, true, blocks.writer(std.testing.allocator), &waiter));
    fixture.recorder.response_status = .unauthorized;
    try std.testing.expectError(error.ChatAgentTokenRequired, listenLoop(&context, directory, 5, false, blocks.writer(std.testing.allocator), &waiter));
    try std.testing.expectEqual(@as(usize, 0), waiter.count);
}

test "chat validates interval reply text missing arguments and missing human turn" {
    try std.testing.expectEqual(@as(u64, 5), try interval(null));
    try std.testing.expectEqual(@as(u64, 60), try interval("60"));
    for ([_][]const u8{ "0", "-1", "61", "1.5", "abc", "18446744073709551615" }) |raw| {
        try std.testing.expectError(error.InvalidInterval, interval(raw));
    }
    var fixture = try TestContext.init(&.{ "chat", "reply", "chat-1", "--text", "  " });
    defer fixture.deinit();
    var context = fixture.context();
    try std.testing.expectError(error.InvalidChatText, reply(&context));
    try std.testing.expectEqual(@as(usize, 0), fixture.recorder.responses_index);
    var no_turn = try TestContext.init(&.{ "chat", "reply", "chat-1", "--text", "Hello" });
    defer no_turn.deinit();
    var no_turn_context = no_turn.context();
    no_turn.recorder.responses = &.{"{\"messages\":[{\"role\":\"assistant\",\"id\":\"bot\"}]}"};
    try std.testing.expectError(error.NoChatMessageToReplyTo, reply(&no_turn_context));
    try std.testing.expectEqual(std.http.Method.GET, no_turn.recorder.method.?);
    var missing_chat = try TestContext.init(&.{ "chat", "reply", "--text", "Hello" });
    defer missing_chat.deinit();
    var missing_chat_context = missing_chat.context();
    try std.testing.expectError(error.MissingArgument, reply(&missing_chat_context));
    var missing_text = try TestContext.init(&.{ "chat", "reply", "chat-1" });
    defer missing_text.deinit();
    var missing_text_context = missing_text.context();
    try std.testing.expectError(error.MissingOption, reply(&missing_text_context));
}

test "chat inbox 5xx backs off after successful heartbeats" {
    var fixture = try TestContext.init(&.{ "chat", "listen" });
    defer fixture.deinit();
    var context = fixture.context();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realpathAlloc(context.allocator, ".");
    var blocks: std.ArrayListUnmanaged(u8) = .{};
    defer blocks.deinit(std.testing.allocator);
    fixture.recorder.response_statuses = &.{ .ok, .service_unavailable, .ok, .internal_server_error, .ok, .ok };
    fixture.recorder.responses = &.{ "{}", "{}", "{}", "{}", "{}", "{\"messages\":[]}" };
    var waiter = TestWaiter{ .recorder = &fixture.recorder, .recover_after = 8 };
    try listenLoop(&context, directory, 5, false, blocks.writer(std.testing.allocator), &waiter);
    try std.testing.expectEqualSlices(u64, &.{ 10, 20, 5 }, waiter.delays[0..waiter.count]);
    try std.testing.expectEqual(@as(usize, 6), fixture.recorder.responses_index);
}

test "chat state follows authenticated identity and API across token rotation" {
    var fixture = try TestContext.init(&.{ "chat", "listen", "--once" });
    defer fixture.deinit();
    var context = fixture.context();
    fixture.recorder.responses = &.{
        "{\"connected_agent\":{\"id\":\"one\"}}",
        "{\"connected_agent\":{\"id\":\"one\"}}",
        "{\"connected_agent\":{\"id\":\"two\"}}",
        "{\"connected_agent\":{\"id\":\"one\"}}",
        "{\"connected_agent\":null}",
    };
    const first = try stateDirectory(&context);
    fixture.cfg.token = "rotated-test-token";
    const rotated = try stateDirectory(&context);
    try std.testing.expectEqualStrings(first, rotated);
    const other_agent = try stateDirectory(&context);
    try std.testing.expect(!std.mem.eql(u8, first, other_agent));
    fixture.cfg.api_url = "https://other.example.test/api";
    const other_api = try stateDirectory(&context);
    try std.testing.expect(!std.mem.eql(u8, first, other_api));
    try std.testing.expectError(error.ChatAgentTokenRequired, stateDirectory(&context));
    try std.testing.expectEqualStrings("/mcp/user/context", fixture.recorder.path.?);
}

test "chat listen command rejects invalid intervals before HTTP or state" {
    var fixture = try TestContext.init(&.{ "chat", "listen", "--interval", "0" });
    defer fixture.deinit();
    var context = fixture.context();
    try std.testing.expectError(error.InvalidInterval, run(&context, "listen"));
    try std.testing.expectEqual(@as(usize, 0), fixture.recorder.responses_index);
}

test "chat SIGINT exits cleanly with zero status" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const child = try std.posix.fork();
    if (child == 0) {
        const action = std.posix.Sigaction{ .handler = .{ .handler = interrupt }, .mask = std.posix.sigemptyset(), .flags = 0 };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);
        std.posix.raise(std.posix.SIG.INT) catch std.posix.exit(99);
        std.posix.exit(98);
    }
    const result = std.posix.waitpid(child, 0);
    try std.testing.expect(std.posix.W.IFEXITED(result.status));
    try std.testing.expectEqual(@as(u8, 0), std.posix.W.EXITSTATUS(result.status));
}
