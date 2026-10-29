const std = @import("std");
const Context = @import("../command_context.zig").Context;
const config = @import("../config.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");
const http = @import("../http.zig");

const saved_login = "{\"success\":true,\"saved\":true,\"configPath\":\"~/.hypertask/config.json\"}";

pub fn login(context: *const Context) !void {
    const device_token = if (context.args.get("code")) |code| try @import("device_login.zig").login(context, code) else null;
    defer if (device_token) |issued| context.allocator.free(issued);
    const login_token = device_token orelse context.args.get("token") orelse return output.invalidOptions("Create or open an agent at https://app.hypertask.ai/agents, copy its token, then run: hypertask login --token <token>");
    try config.saveToken(context.cfg, login_token, context.cfg.api_url);
    if (device_token != null) try @import("device_login.zig").acknowledge(context, login_token);
    var timer = std.time.Timer.start() catch return context.print(saved_login);
    const deadline_ns = 1500 * std.time.ns_per_ms;
    const job = LoginGuideJob.init(context, login_token) catch return context.print(saved_login);
    const elapsed = timer.read();
    if (elapsed >= deadline_ns) {
        job.deinit();
        return context.print(saved_login);
    }
    const worker = std.Thread.spawn(.{}, LoginGuideJob.run, .{job}) catch {
        job.deinit();
        return context.print(saved_login);
    };
    job.done.timedWait(deadline_ns - elapsed) catch {
        // A stalled worker owns its client and all memory until process exit.
        // Never join it or free its state on this best-effort timeout path.
        worker.detach();
        return context.print(saved_login);
    };
    worker.join();
    defer job.deinit();
    const guide = job.guide orelse return context.print(saved_login);
    // Human guidance is already formatted, not a JSON response to render.
    try output.print(guide);
}

const LoginGuideJob = struct {
    arena: std.heap.ArenaAllocator,
    api_url: []const u8,
    token: []const u8,
    json_mode: bool,
    guide: ?[]const u8 = null,
    done: std.Thread.Semaphore = .{},

    fn init(context: *const Context, login_token: []const u8) !*LoginGuideJob {
        const job = try std.heap.page_allocator.create(LoginGuideJob);
        job.* = .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .api_url = undefined,
            .token = undefined,
            .json_mode = context.json,
        };
        errdefer job.deinit();
        const owned = job.arena.allocator();
        job.api_url = try owned.dupe(u8, context.cfg.api_url);
        job.token = try owned.dupe(u8, login_token);
        return job;
    }

    fn run(self: *LoginGuideJob) void {
        defer self.done.post();
        var client = std.http.Client{ .allocator = std.heap.page_allocator };
        defer client.deinit();
        const allocator = self.arena.allocator();
        var response = http.requestWithToken(&client, allocator, self.api_url, self.token, .GET, "/mcp/hello", null) catch return;
        defer response.deinit();
        if (!response.isSuccess()) return;
        self.guide = buildLoginGuide(allocator, response.body, self.json_mode) catch null;
    }

    fn deinit(self: *LoginGuideJob) void {
        self.arena.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

const LoginHello = struct {
    const User = struct { displayName: ?[]const u8 = null, email: ?[]const u8 = null };
    const Board = struct { id: i64, title: []const u8, boardUrl: []const u8 };
    const Step = struct { step: []const u8, command: []const u8 };

    success: bool = true,
    user: User,
    agent: ?struct { displayName: ?[]const u8 = null } = null,
    boards: []const Board,
    boardsTotal: ?i64 = null,
    startBoard: ?Board = null,
    nextSteps: ?[]const Step = null,
};

fn buildLoginGuide(allocator: std.mem.Allocator, body: []const u8, json_mode: bool) ![]u8 {
    const parsed = try std.json.parseFromSlice(LoginHello, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const hello = parsed.value;
    if (!hello.success) return error.InvalidResponse;
    const user_name = hello.user.displayName orelse hello.user.email orelse return error.InvalidResponse;
    const name = if (hello.agent) |agent| agent.displayName orelse user_name else user_name;
    const board = hello.startBoard orelse if (hello.boards.len != 0) hello.boards[0] else null;
    const total = hello.boardsTotal orelse @as(i64, @intCast(hello.boards.len));
    var fallback = [_]LoginHello.Step{
        .{ .step = "See the board", .command = "" },
        .{ .step = "Create a first task", .command = "" },
        .{ .step = "Read the board rules", .command = "" },
    };
    defer for (fallback) |step| {
        if (step.command.len != 0) allocator.free(step.command);
    };
    if (hello.nextSteps == null) if (board) |value| {
        fallback[0].command = try std.fmt.allocPrint(allocator, "hypertask task list --project {d}", .{value.id});
        fallback[1].command = try std.fmt.allocPrint(allocator, "hypertask task create --project {d} --title \"My first task\"", .{value.id});
        fallback[2].command = try std.fmt.allocPrint(allocator, "hypertask project playbook {d}", .{value.id});
    };
    const steps = hello.nextSteps orelse if (board != null) &fallback else &.{};

    if (!json_mode) {
        var text: std.Io.Writer.Allocating = .init(allocator);
        defer text.deinit();
        const writer = &text.writer;
        try writer.print("Signed in as {s}", .{name});
        if (hello.agent != null) try writer.print(" (agent of {s})", .{user_name});
        try writer.writeByte('\n');
        if (board) |value| {
            try writer.print("Board: {s}\n{s}\n", .{ value.title, value.boardUrl });
            if (total > 1) try writer.print("You have {d} boards: hypertask project list\n", .{total});
        } else {
            try writer.writeAll("No board yet. Create one in your Hypertask web app.\n");
        }
        if (steps.len != 0) {
            try writer.writeAll("\nNext steps your agent can run now:\n");
            for (steps, 0..) |step, index| {
                try writer.print("  {d}. {s}:", .{ index + 1, step.step });
                try writer.splatByteAll(' ', @max(1, 23 -| step.step.len));
                try writer.print("{s}\n", .{step.command});
            }
        }
        try writer.writeAll("\nOr just ask your agent: \"What's on my Hypertask board?\"\n");
        return text.toOwnedSlice();
    }

    var object = try json.Object.init(allocator);
    defer object.deinit();
    try object.boolean("success", true);
    try object.boolean("saved", true);
    try object.string("configPath", "~/.hypertask/config.json");
    var identity = try json.Object.init(allocator);
    defer identity.deinit();
    try identity.string("name", name);
    if (hello.agent != null) try identity.string("owner", user_name);
    try object.raw("signedInAs", try identity.finish());
    if (board) |value| {
        var board_object = try json.Object.init(allocator);
        defer board_object.deinit();
        try board_object.integer("id", value.id);
        try board_object.string("title", value.title);
        try board_object.string("url", value.boardUrl);
        try object.raw("board", try board_object.finish());
    } else try object.nullValue("board");
    var next_steps: std.Io.Writer.Allocating = .init(allocator);
    defer next_steps.deinit();
    try next_steps.writer.writeByte('[');
    for (steps, 0..) |step, index| {
        if (index != 0) try next_steps.writer.writeByte(',');
        var next = try json.Object.init(allocator);
        defer next.deinit();
        try next.string("step", step.step);
        try next.string("command", step.command);
        try next_steps.writer.writeAll(try next.finish());
    }
    try next_steps.writer.writeByte(']');
    try object.raw("nextSteps", next_steps.written());
    if (total > 1) {
        var more = try json.Object.init(allocator);
        defer more.deinit();
        try more.integer("total", total);
        try more.string("command", "hypertask project list");
        try object.raw("moreBoards", try more.finish());
    }
    return allocator.dupe(u8, try object.finish());
}

pub fn logout(context: *const Context) !void {
    if (context.args.get("token") != null) {
        try context.print("{\"success\":true,\"message\":\"Saved authentication unchanged\"}");
        return;
    }
    if (context.cfg.token.len != 0) {
        var response = context.fetchRaw(.DELETE, "/mcp/token", null) catch null;
        if (response) |*value| value.deinit();
    }
    try config.clear(context.allocator);
    try context.print("{\"success\":true,\"message\":\"Logged out\"}");
}

pub fn status(context: *const Context) !void {
    var object = try json.Object.init(context.allocator);
    defer object.deinit();
    try object.boolean("authenticated", context.cfg.token.len != 0);
    try object.boolean("hasToken", context.cfg.token.len != 0);
    try appendTokenIdentity(context.allocator, &object, context.cfg.token);
    try object.string("apiUrl", context.cfg.api_url);
    const path = try config.configPath(context.allocator);
    try object.string("configPath", path);
    try context.print(try object.finish());
}

fn appendTokenIdentity(allocator: std.mem.Allocator, object: *json.Object, token_value: []const u8) !void {
    var segments = std.mem.splitScalar(u8, token_value, '.');
    _ = segments.next() orelse return appendUnknownIdentity(object);
    const encoded_payload = segments.next() orelse return appendUnknownIdentity(object);
    _ = segments.next() orelse return appendUnknownIdentity(object);
    if (segments.next() != null) return appendUnknownIdentity(object);

    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded_payload) catch return appendUnknownIdentity(object);
    const payload = try allocator.alloc(u8, decoded_size);
    defer allocator.free(payload);
    std.base64.url_safe_no_pad.Decoder.decode(payload, encoded_payload) catch return appendUnknownIdentity(object);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return appendUnknownIdentity(object);
    defer parsed.deinit();
    if (parsed.value != .object) return appendUnknownIdentity(object);

    const agent_id = parsed.value.object.get("agentId");
    const is_agent = if (agent_id) |value| value == .string or value == .integer else false;
    try object.string("identity", if (is_agent) "agent" else "user");
    if (agent_id) |value| {
        switch (value) {
            .string => |id| try object.string("agentId", id),
            .integer => |id| try object.integer("agentId", id),
            else => try object.nullValue("agentId"),
        }
    } else {
        try object.nullValue("agentId");
    }

    const exp = parsed.value.object.get("exp");
    if (exp != null and exp.? == .integer) {
        if (try formatExpiry(allocator, exp.?.integer)) |formatted| {
            defer allocator.free(formatted);
            try object.string("expiresAt", formatted);
            return;
        }
    }
    try object.nullValue("expiresAt");
}

fn appendUnknownIdentity(object: *json.Object) !void {
    try object.string("identity", "user");
    try object.nullValue("agentId");
    try object.nullValue("expiresAt");
}

fn formatExpiry(allocator: std.mem.Allocator, seconds: i64) !?[]u8 {
    if (seconds < 0 or seconds > 253_402_300_799) return null;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

pub fn token(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "set-management-key")) {
        const key = try context.args.requirePositional(2, "key");
        if (!std.mem.startsWith(u8, key, "htmk_")) return output.invalidOptions("management key must start with htmk_");
        try config.saveManagementKey(context.allocator, key);
        try context.print("{\"success\":true,\"saved\":true,\"configPath\":\"~/.hypertask/config.json\"}");
        return;
    }
    if (!std.mem.eql(u8, subcommand, "refresh")) return output.unknownCommand("unknown token command");
    try context.requireAuth();
    var response = try context.fetch(.POST, "/mcp/token/refresh", null);
    defer response.deinit();

    if (!response.isSuccess()) return output.finish(&response);

    var saved = false;
    if (context.args.get("token") == null and !try config.hasEnvironmentToken(context.allocator)) {
        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("token")) |token_value| if (token_value == .string) {
            try config.saveToken(context.cfg, token_value.string, context.cfg.api_url);
            saved = true;
        };
    }
    if (!saved) return context.print(response.body);

    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    var object = try json.Object.init(context.allocator);
    defer object.deinit();
    try object.boolean("success", true);
    if (parsed.value.object.get("token")) |value| if (value == .string) try object.string("token", value.string);
    if (parsed.value.object.get("expiresAt")) |value| if (value == .string) try object.string("expiresAt", value.string);
    try object.boolean("saved", true);
    try context.print(try object.finish());
}

const agent_hello =
    \\{"success":true,"user":{"displayName":"Maria Lopez","email":"m@example.com"},"agent":{"id":"agent-1","displayName":"Claude Code"},"boards":[{"id":9142,"title":"Product Launch","boardUrl":"https://app.hypertask.ai/project?id=9142"}],"boardsTotal":1}
;

const agent_guide =
    \\Signed in as Claude Code (agent of Maria Lopez)
    \\Board: Product Launch
    \\https://app.hypertask.ai/project?id=9142
    \\
    \\Next steps your agent can run now:
    \\  1. See the board:          hypertask task list --project 9142
    \\  2. Create a first task:    hypertask task create --project 9142 --title "My first task"
    \\  3. Read the board rules:   hypertask project playbook 9142
    \\
    \\Or just ask your agent: "What's on my Hypertask board?"
    \\
;

test "login worker copies normalized API URL and login token instead of raw arguments" {
    const allocator = std.testing.allocator;
    const args = @import("../args.zig");
    var parsed = try args.parse(allocator, &.{ "login", "--token", "new-token", "--api-url", "http://host/api/" });
    defer parsed.deinit();
    var cfg = try config.loadAllowingEmptyToken(allocator, parsed.get("token"), parsed.get("api-url"), null);
    defer cfg.deinit();
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = Context{ .client = &client, .allocator = allocator, .args = &parsed, .cfg = &cfg, .json = true };
    const job = try LoginGuideJob.init(&context, parsed.get("token").?);
    defer job.deinit();
    try std.testing.expectEqualStrings("http://host/api/", parsed.get("api-url").?);
    try std.testing.expectEqualStrings("http://host/api", job.api_url);
    try std.testing.expectEqualStrings("new-token", job.token);
    try std.testing.expect(job.api_url.ptr != cfg.api_url.ptr);
    try std.testing.expect(job.token.ptr != parsed.get("token").?.ptr);
}

test "login guide honors two server steps for read-only agents" {
    const allocator = std.testing.allocator;
    const body =
        \\{"user":{"email":"m@example.com"},"boards":[{"id":7,"title":"Only Board","boardUrl":"https://example.test/board/7"}],"nextSteps":[{"step":"Browse tasks","command":"hypertask task list --project 7","tool":"renamed_list_tool","arguments":{"project_id":7}},{"step":"Check rules","command":"hypertask project playbook 7","tool":"renamed_rules_tool"}]}
    ;
    const result = try buildLoginGuide(allocator, body, true);
    defer allocator.free(result);
    try std.testing.expect(std.mem.startsWith(u8, result, saved_login[0 .. saved_login.len - 1]));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const steps = parsed.value.object.get("nextSteps").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("Browse tasks", json.stringField(steps[0], "step").?);
    try std.testing.expectEqualStrings("hypertask task list --project 7", json.stringField(steps[0], "command").?);
    try std.testing.expectEqualStrings("Check rules", json.stringField(steps[1], "step").?);
    try std.testing.expectEqualStrings("hypertask project playbook 7", json.stringField(steps[1], "command").?);
    const human = try buildLoginGuide(allocator, body, false);
    defer allocator.free(human);
    try std.testing.expect(std.mem.indexOf(u8, human, "1. Browse tasks:") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "2. Check rules:") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "create") == null);
}

test "login guide does not invent commands for explicitly empty server steps" {
    const allocator = std.testing.allocator;
    const body =
        \\{"user":{"email":"m@example.com"},"boards":[{"id":7,"title":"Only Board","boardUrl":"https://example.test/board/7"}],"nextSteps":[]}
    ;
    const result = try buildLoginGuide(allocator, body, true);
    defer allocator.free(result);
    try std.testing.expect(std.mem.endsWith(u8, result, "\"nextSteps\":[]}"));
    const human = try buildLoginGuide(allocator, body, false);
    defer allocator.free(human);
    try std.testing.expect(std.mem.indexOf(u8, human, "Next steps") == null);
}

test "login guide shows agent owner and exact next steps" {
    const allocator = std.testing.allocator;
    const human = try buildLoginGuide(allocator, agent_hello, false);
    defer allocator.free(human);
    try std.testing.expectEqualStrings(agent_guide, human);
    const result = try buildLoginGuide(allocator, agent_hello, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"success":true,"saved":true,"configPath":"~/.hypertask/config.json","signedInAs":{"name":"Claude Code","owner":"Maria Lopez"},"board":{"id":9142,"title":"Product Launch","url":"https://app.hypertask.ai/project?id=9142"},"nextSteps":[{"step":"See the board","command":"hypertask task list --project 9142"},{"step":"Create a first task","command":"hypertask task create --project 9142 --title \"My first task\""},{"step":"Read the board rules","command":"hypertask project playbook 9142"}]}
    , result);
}

test "login guide accepts old server user and first board without agent" {
    const allocator = std.testing.allocator;
    const body =
        \\{"user":{"displayName":"Maria Lopez","email":"m@example.com"},"boards":[{"id":7,"title":"Only Board","boardUrl":"https://app.hypertask.ai/project?id=7"}]}
    ;
    const result = try buildLoginGuide(allocator, body, true);
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const identity = json.objectField(parsed.value, "signedInAs").?;
    try std.testing.expectEqualStrings("Maria Lopez", json.stringField(identity, "name").?);
    try std.testing.expect(identity.object.get("owner") == null);
    try std.testing.expectEqual(@as(i64, 7), json.integerField(json.objectField(parsed.value, "board").?, "id", false).?);
    const human = try buildLoginGuide(allocator, body, false);
    defer allocator.free(human);
    try std.testing.expect(std.mem.startsWith(u8, human, "Signed in as Maria Lopez\nBoard: Only Board\n"));
}

test "login guide prefers startBoard and lists additional boards" {
    const allocator = std.testing.allocator;
    const body =
        \\{"user":{"email":"m@example.com"},"agent":null,"boards":[{"id":1,"title":"Alpha","boardUrl":"https://app.hypertask.ai/project?id=1"}],"boardsTotal":3,"startBoard":{"id":2,"title":"Beta","boardUrl":"https://app.hypertask.ai/project?id=2"}}
    ;
    const result = try buildLoginGuide(allocator, body, true);
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), json.integerField(json.objectField(parsed.value, "board").?, "id", false).?);
    const more = json.objectField(parsed.value, "moreBoards").?;
    try std.testing.expectEqual(@as(i64, 3), json.integerField(more, "total", false).?);
    try std.testing.expectEqualStrings("hypertask project list", json.stringField(more, "command").?);
    const human = try buildLoginGuide(allocator, body, false);
    defer allocator.free(human);
    try std.testing.expect(std.mem.startsWith(u8, human, "Signed in as m@example.com\nBoard: Beta\nhttps://app.hypertask.ai/project?id=2\nYou have 3 boards: hypertask project list\n"));
    try std.testing.expect(std.mem.indexOf(u8, human, "hypertask task list --project 2") != null);
}

test "login guide handles no boards and missing agent display name" {
    const allocator = std.testing.allocator;
    const body =
        \\{"user":{"email":"m@example.com"},"agent":{"id":"agent-1"},"boards":[],"boardsTotal":0,"startBoard":null}
    ;
    const result = try buildLoginGuide(allocator, body, true);
    defer allocator.free(result);
    try std.testing.expectEqualStrings(
        \\{"success":true,"saved":true,"configPath":"~/.hypertask/config.json","signedInAs":{"name":"m@example.com","owner":"m@example.com"},"board":null,"nextSteps":[]}
    , result);
    const human = try buildLoginGuide(allocator, body, false);
    defer allocator.free(human);
    try std.testing.expectEqualStrings("Signed in as m@example.com (agent of m@example.com)\nNo board yet. Create one in your Hypertask web app.\n\nOr just ask your agent: \"What's on my Hypertask board?\"\n", human);
}

test "login guide escapes server strings and rejects invalid hello" {
    const allocator = std.testing.allocator;
    const body =
        \\{"user":{"displayName":"Maria \"M\"\nLopez"},"boards":[{"id":1,"title":"Product \"Launch\"","boardUrl":"https://app.hypertask.ai/project?id=1"}]}
    ;
    const result = try buildLoginGuide(allocator, body, true);
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Maria \"M\"\nLopez", json.stringField(json.objectField(parsed.value, "signedInAs").?, "name").?);
    try std.testing.expectEqualStrings("Product \"Launch\"", json.stringField(json.objectField(parsed.value, "board").?, "title").?);
    for ([_][]const u8{ "not json", "null", "{}", "[]", "{\"user\":null,\"boards\":[]}", "{\"success\":false,\"user\":{\"email\":\"m@example.com\"},\"boards\":[]}" }) |invalid| {
        if (buildLoginGuide(allocator, invalid, true)) |unexpected| {
            allocator.free(unexpected);
            return error.ExpectedInvalidHello;
        } else |_| {}
    }
}
