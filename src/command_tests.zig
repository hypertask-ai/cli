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
    return expectDispatchErrorWithResponses(argv, &.{}, expected);
}

fn expectDispatchErrorWithResponses(argv: []const []const u8, responses: []const []const u8, expected: anyerror) !void {
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

test "tasks list resolves --labels into a labels query filter" {
    try expectRequestWithResponses(
        &.{ "tasks", "list", "--project", "15", "--labels", "auto-error" },
        &.{"{\"projects\":[{\"id\":15,\"labels\":[{\"id\":\"auto-error-label-id\",\"name\":\"auto-error\"}]}]}"},
        .GET,
        "/mcp/tasks?project_id=15&labels=auto-error-label-id&limit=10&offset=0",
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

test "task assign --assignee <agent-uuid> is confirmed by that exact agent in the response" {
    try expectRequestWithResponses(
        &.{ "task", "assign", "HTPR-6136", "--assignee", "agent-1" },
        &.{"{\"assignees\":[{\"userId\":6,\"agent\":{\"id\":\"agent-1\"}}]}"},
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"agent_id\":\"agent-1\",\"intent\":\"assign\"}",
    );
}

test "task assign --assignee <agent-uuid> fails when the response shows a different agent" {
    try expectDispatchErrorWithResponses(
        &.{ "task", "assign", "HTPR-6136", "--assignee", "agent-1" },
        &.{"{\"assignees\":[{\"userId\":6,\"agent\":{\"id\":\"agent-2\"}}]}"},
        error.AssigneeNotConfirmed,
    );
}

test "task unassign --assignee <agent-uuid> succeeds when the row is gone" {
    try expectRequestWithResponses(
        &.{ "task", "unassign", "HTPR-6136", "--assignee", "agent-1" },
        &.{"{\"assignees\":[{\"userId\":6}]}"},
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"agent_id\":\"agent-1\",\"intent\":\"unassign\"}",
    );
}

test "task unassign --assignee <agent-uuid> fails when the agent row survives" {
    try expectDispatchErrorWithResponses(
        &.{ "task", "unassign", "HTPR-6136", "--assignee", "agent-1" },
        &.{"{\"assignees\":[{\"userId\":6,\"agent\":{\"id\":\"agent-1\"}}]}"},
        error.AssigneeNotRemoved,
    );
}

test "task unassign --assignee <user-id> removes agent-linked rows via their agent id" {
    // HTPR-6311: `tasks get` shows this row under user id 6, but a user_id
    // unassign silently no-ops on agent-linked rows.
    try expectRequestWithResponses(
        &.{ "task", "unassign", "HTPR-6136", "--assignee", "6" },
        &.{ "{\"tasks\":[{\"id\":38870,\"assignees\":[{\"id\":6,\"agent\":{\"id\":\"agent-1\"}}]}]}", "{}" },
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"agent_id\":\"agent-1\",\"intent\":\"unassign\"}",
    );
}

test "task unassign --assignee <user-id> removes a plain row via user_id" {
    try expectRequestWithResponses(
        &.{ "task", "unassign", "HTPR-6136", "--assignee", "6" },
        &.{ "{\"tasks\":[{\"id\":38870,\"assignees\":[{\"id\":6}]}]}", "{}" },
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"user_id\":6,\"intent\":\"unassign\"}",
    );
}

test "task unassign --assignee <user-id> removes plain and agent rows, then verifies" {
    try expectRequestWithResponses(
        &.{ "task", "unassign", "HTPR-6136", "--assignee", "6" },
        &.{
            "{\"tasks\":[{\"id\":38870,\"assignees\":[{\"id\":6,\"agent\":{\"id\":\"agent-1\"}},{\"id\":6}]}]}",
            "{}",
            "{\"assignees\":[]}",
        },
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"user_id\":6,\"intent\":\"unassign\"}",
    );
}

test "task unassign --assignee <user-id> with no matching rows stays an idempotent no-op" {
    try expectRequestWithResponses(
        &.{ "task", "unassign", "HTPR-6136", "--assignee", "6" },
        &.{ "{\"tasks\":[{\"id\":38870,\"assignees\":[{\"id\":7}]}]}", "{}" },
        .POST,
        "/mcp/assignees/assign",
        "{\"ticket_number\":\"HTPR-6136\",\"user_id\":6,\"intent\":\"unassign\"}",
    );
}

test "task update --description-file reads the file and takes precedence over --description" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "description.html", .data = "<p>from file</p>" });
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "description.html" });
    defer std.testing.allocator.free(path);

    try expectRequest(
        &.{ "task", "update", "HTPR-6136", "--description", "ignored", "--description-file", path },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6136\",\"description\":\"<p>from file</p>\"}",
    );
}

test "agents update --visibility sends a visibility-only body" {
    try expectRequest(
        &.{ "agents", "update", "--id", "agent-1", "--visibility", "TEAM" },
        .PATCH,
        "/mcp/agents/agent-1",
        "{\"visibility\":\"TEAM\"}",
    );
    try expectRequest(
        &.{ "agents", "update", "--id", "agent-1", "--visibility", "PRIVATE" },
        .PATCH,
        "/mcp/agents/agent-1",
        "{\"visibility\":\"PRIVATE\"}",
    );
}

test "agents update refuses to mix visibility with project changes or an unknown value" {
    try expectDispatchError(
        error.InvalidOptions,
        &.{ "agents", "update", "--id", "agent-1", "--visibility", "TEAM", "--add-project", "15" },
    );
    try expectDispatchError(
        error.InvalidOptions,
        &.{ "agents", "update", "--id", "agent-1", "--visibility", "PUBLIC" },
    );
}

// The refused-sharing answer the user actually reads is the server's error
// body, so assert it reaches stdout before the exit code is chosen.
test "a refused visibility change prints the server error body" {
    const posix = std.posix;
    const http = @import("http.zig");
    const output = @import("output.zig");

    var body_storage =
        ("{\"success\":false,\"error\":\"Enable a provider key before sharing this agent with the team (TEAM_VISIBILITY_KEY_REQUIRED)\"}").*;
    var response = http.Response{ .status = .conflict, .body = &body_storage, .allocator = std.testing.allocator };

    const pipe = try posix.pipe();
    const saved_stdout = try posix.dup(1);
    try posix.dup2(pipe[1], 1);
    const result = output.finish(&response);
    try posix.dup2(saved_stdout, 1);
    posix.close(saved_stdout);
    posix.close(pipe[1]);

    try std.testing.expectError(error.ApiFailure, result);
    var captured: [512]u8 = undefined;
    const printed = try posix.read(pipe[0], &captured);
    posix.close(pipe[0]);
    try std.testing.expect(std.mem.indexOf(u8, captured[0..printed], "TEAM_VISIBILITY_KEY_REQUIRED") != null);
}

