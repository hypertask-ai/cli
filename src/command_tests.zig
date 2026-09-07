const std = @import("std");
const args = @import("args.zig");
const command_context = @import("command_context.zig");
const config = @import("config.zig");
const router = @import("router.zig");

fn expectRequest(argv: []const []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
    return expectRequestWithResponses(argv, &.{}, method, path, body);
}

fn expectRequestWithResponses(argv: []const []const u8, responses: []const []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
    defer cfg.deinit();
    var recorder = command_context.RequestRecorder.init(allocator);
    defer recorder.deinit();
    recorder.responses = responses;
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

test "task get distinguishes internal ids from project ticket indexes" {
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
    try expectRequest(
        &.{ "tasks", "get", "id:35672" },
        .GET,
        "/mcp/tasks?task_id=35672",
        null,
    );
    try expectDispatchError(error.AmbiguousTaskIdentifier, &.{ "tasks", "get", "6162" });
    try expectDispatchError(error.AmbiguousTaskIdentifier, &.{ "comment", "add", "6162", "--text", "hi" });
}

test "messages poll rejects invalid cursors before making a request" {
    try expectDispatchError(error.InvalidInteger, &.{ "messages", "poll", "--since", "-1" });
    try expectDispatchError(error.InvalidInteger, &.{ "messages", "poll", "--since", "not-a-number" });
}

test "webhook configure passes server-owned event names through" {
    try expectRequest(
        &.{ "webhook", "configure", "--event", "comment.mention", "--event", "task.assigned", "--event", "task.unassigned", "--event", "comment.created", "--event", "task.updated", "--event", "task.created", "--event", "chat.message" },
        .POST,
        "/mcp/webhooks",
        "{\"action\":\"configure\",\"agent_id\":\"self\",\"events\":[\"comment.mention\",\"task.assigned\",\"task.unassigned\",\"comment.created\",\"task.updated\",\"task.created\",\"chat.message\"]}",
    );
}

test "command handlers build request bodies and query strings without HTTP" {
    try expectRequest(
        &.{ "task", "create", "--project", "15", "--title", "Fix it", "--priority", "high", "--estimate", "3" },
        .POST,
        "/mcp/tasks/create",
        "{\"project_id\":15,\"title\":\"Fix it\",\"priority\":2,\"estimate\":3}",
    );
    try expectRequest(
        &.{ "task", "update", "HTPR-5899", "--pull-request", "https://github.com/hypertask-ai/hypertask/pull/149" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-5899\",\"pull_request_url\":\"https://github.com/hypertask-ai/hypertask/pull/149\"}",
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6234", "--project", "15", "--add-labels", "QA ✅" },
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"projects\":[{\"id\":15,\"labels\":[{\"id\":\"qa-label-id\",\"name\":\"QA ✅\"}]}]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6234\",\"project_id\":15,\"add_labels\":[\"qa-label-id\"]}",
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6234", "--project", "15", "--remove-labels", "11111111-2222-4333-8444-555555555555", "--add-labels", "CLI" },
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"projects\":[{\"id\":15,\"labels\":[{\"id\":\"cli-label-id\",\"name\":\"CLI\"}]}]}", "{\"projects\":[{\"id\":15,\"labels\":[]}]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6234\",\"project_id\":15,\"add_labels\":[\"cli-label-id\"],\"remove_labels\":[\"11111111-2222-4333-8444-555555555555\"]}",
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
        &.{ "messages", "poll", "--since", "10" },
        .GET,
        "/mcp/inbox/list",
        null,
    );
    try expectRequest(
        &.{ "draft", "create", "id:123", "--text", "Hello", "--comment" },
        .POST,
        "/mcp/drafts",
        "{\"task_id\":123,\"text\":\"Hello\",\"draft_type\":\"comment\"}",
    );
    try expectRequest(
        &.{ "draft", "create", "6162", "--project", "15", "--text", "Hello", "--comment" },
        .POST,
        "/mcp/drafts",
        "{\"unique_index\":6162,\"project_id\":15,\"text\":\"Hello\",\"draft_type\":\"comment\"}",
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
    try expectRequest(
        &.{ "comment", "react", "216402", "--emoji", "✅" },
        .POST,
        "/mcp/comments/216402/reactions",
        "{\"emoji\":\"✅\",\"active\":true}",
    );
    try expectRequest(
        &.{ "comment", "unreact", "216402", "--emoji", "✅" },
        .POST,
        "/mcp/comments/216402/reactions",
        "{\"emoji\":\"✅\",\"active\":false}",
    );
}

test "comment reactions require an emoji" {
    try expectDispatchError(error.MissingOption, &.{ "comment", "react", "216402" });
    try expectDispatchError(error.MissingOption, &.{ "comment", "unreact", "216402" });
}

test "the local agent dev loop refuses to guess an agent or a handler URL" {
    // `--agent` has no default on purpose: a stray `agent dev` in the wrong
    // shell must not be able to repoint a live agent's webhook.
    try expectDispatchError(error.MissingOption, &.{ "agent", "dev", "--port", "3000" });
    try expectDispatchError(error.MissingOption, &.{ "agent", "dev", "--agent", "a1" });
    try expectDispatchError(error.InvalidOptions, &.{ "agent", "dev", "--agent", "a1", "--port", "3000", "--path", "hook" });
    try expectDispatchError(error.MissingOption, &.{ "agent", "replay", "run_1" });
    try expectDispatchError(error.InvalidOptions, &.{ "agent", "replay", "run_1", "--url", "file:///etc/passwd" });
}

test "task assign --self sends assign_self without requiring --assignee" {
    try expectRequest(
        &.{ "task", "assign", "HTPR-6136", "--self" },
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"assign_self\":true,\"intent\":\"assign\"}",
    );
}
