const std = @import("std");
const args = @import("args.zig");
const command_context = @import("command_context.zig");
const config = @import("config.zig");
const router = @import("router.zig");

fn expectRequest(argv: []const []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
    defer cfg.deinit();
    var recorder = command_context.RequestRecorder.init(allocator);
    defer recorder.deinit();
    const context = command_context.Context{
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = true,
        .request_recorder = &recorder,
    };

    try router.dispatch(&context);
    try std.testing.expectEqual(method, recorder.method.?);
    try std.testing.expectEqualStrings(path, recorder.path.?);
    if (body) |expected| {
        try std.testing.expectEqualStrings(expected, recorder.body.?);
    } else {
        try std.testing.expect(recorder.body == null);
    }
}

fn expectDispatchError(expected: anyerror, argv: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
    defer cfg.deinit();
    const context = command_context.Context{
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = true,
    };

    try std.testing.expectError(expected, router.dispatch(&context));
}

test "router dispatches task and decision aliases" {
    try expectRequest(
        &.{ "task", "list", "--project", "15" },
        .GET,
        "/mcp/tasks?project_id=15&limit=10&offset=0",
        null,
    );
    try expectRequest(
        &.{ "tasks", "list", "--project", "15" },
        .GET,
        "/mcp/tasks?project_id=15&limit=10&offset=0",
        null,
    );
    try expectRequest(
        &.{ "decision", "list", "htpr-123", "--status", "pending" },
        .GET,
        "/mcp/decisions?ticket_number=HTPR-123&status=pending",
        null,
    );
    try expectRequest(
        &.{ "decisions", "list", "HTPR-123", "--status", "pending" },
        .GET,
        "/mcp/decisions?ticket_number=HTPR-123&status=pending",
        null,
    );
}

test "task get resolves bare numbers as project ticket suffixes" {
    try expectRequest(
        &.{ "tasks", "get", "5661", "--project", "15" },
        .GET,
        "/mcp/tasks?unique_index=5661&project_id=15",
        null,
    );
    try expectRequest(
        &.{ "tasks", "get", "htpr-5661" },
        .GET,
        "/mcp/tasks?ticket_number=HTPR-5661",
        null,
    );
    try expectDispatchError(error.MissingOption, &.{ "tasks", "get", "5661" });
}

test "command handlers build request bodies and query strings without HTTP" {
    try expectRequest(
        &.{ "task", "create", "--project", "15", "--title", "Fix it", "--priority", "high", "--estimate", "3" },
        .POST,
        "/mcp/tasks/create",
        "{\"project_id\":15,\"title\":\"Fix it\",\"priority\":2,\"estimate\":3}",
    );
    try expectRequest(
        &.{ "decision", "create", "htpr-123", "--question", "Pick", "--option", "A", "--option", "B" },
        .POST,
        "/mcp/decisions",
        "{\"ticket_number\":\"HTPR-123\",\"question\":\"Pick\",\"options\":[\"A\",\"B\"]}",
    );
    try expectRequest(
        &.{ "section", "create", "--project", "15", "--title", "Done", "--after", "9" },
        .POST,
        "/mcp/projects/15/sections",
        "{\"title\":\"Done\",\"after_section_id\":9}",
    );
    try expectRequest(
        &.{ "view", "create", "--project", "15", "--title", "Focus", "--label", "bug", "--assignee", "agent-1", "--match", "all", "--default" },
        .POST,
        "/mcp/view",
        "{\"project_id\":15,\"title\":\"Focus\",\"filters\":{\"label_names\":[\"bug\"],\"assignee_ids\":[\"agent-1\"],\"match\":\"all\"},\"set_as_default\":true}",
    );
    try expectRequest(
        &.{ "inbox", "archive", "3", "4" },
        .POST,
        "/mcp/inbox/archive",
        "{\"notification_ids\":[3,4]}",
    );
    try expectRequest(
        &.{ "draft", "create", "123", "--text", "Hello", "--comment" },
        .POST,
        "/mcp/drafts",
        "{\"task_id\":123,\"text\":\"Hello\",\"draft_type\":\"comment\"}",
    );
    try expectRequest(
        &.{ "pages", "get", "7", "--format", "html" },
        .GET,
        "/mcp/pages/get?id=7&format=html",
        null,
    );
    try expectRequest(
        &.{ "project", "invite", "15", "--user", "6" },
        .POST,
        "/mcp/projects/15/members",
        "{\"projectId\":15,\"userToAdd\":6}",
    );
    try expectRequest(
        &.{ "comment", "add", "HTPR-123", "--text", "Hello", "--markdown" },
        .POST,
        "/mcp/comments",
        "{\"ticket_number\":\"HTPR-123\",\"text\":\"Hello\",\"content_type\":\"markdown\"}",
    );
}
