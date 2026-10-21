const std = @import("std");
const args = @import("args.zig");
const command_context = @import("command_context.zig");
const config = @import("config.zig");
const router = @import("router.zig");

fn expectRequest(argv: []const []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
    return expectRequestWithResponses(argv, &.{}, method, path, body);
}

fn expectRequestWithResponses(argv: []const []const u8, responses: []const []const u8, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
    return expectRequestCountWithResponses(argv, responses, null, method, path, body);
}

fn expectRequestCountWithResponses(argv: []const []const u8, responses: []const []const u8, expected_count: ?usize, method: std.http.Method, path: []const u8, body: ?[]const u8) !void {
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
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = command_context.Context{
        .client = &client,
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = true,
        .request_recorder = &recorder,
    };

    try router.dispatch(&context);
    if (expected_count) |count| try std.testing.expectEqual(count, recorder.responses_index);
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
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = command_context.Context{
        .client = &client,
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = true,
        .request_recorder = &recorder,
    };

    try std.testing.expectError(expected, router.dispatch(&context));
}

test "helper write command refuses before HTTP and read command reaches HTTP" {
    const helper_guard = @import("helper_guard.zig");
    helper_guard.testing.helper = true;
    defer helper_guard.testing.helper = null;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var cfg = config.Config{ .allocator = allocator, .token = "test-token", .api_url = "not-a-url" };
    defer cfg.deinit();
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var write_args = try args.parse(allocator, &.{ "comment", "add", "TEST-1", "--text", "blocked" });
    defer write_args.deinit();
    var context = command_context.Context{
        .client = &client,
        .allocator = allocator,
        .args = &write_args,
        .cfg = &cfg,
        .json = true,
    };
    try std.testing.expectError(error.HelperWriteForbidden, router.dispatch(&context));
    var read_args = try args.parse(allocator, &.{ "task", "list", "--project", "15" });
    defer read_args.deinit();
    context.args = &read_args;
    try std.testing.expectError(error.UnexpectedCharacter, router.dispatch(&context));
    try std.testing.expectError(error.HelperWriteForbidden, @import("http.zig").send(&client, allocator, .POST, "not-a-url", &.{}, "{}"));
}

test "time log forwards optional note date and timezone fields" {
    try expectRequest(
        &.{ "--json", "time", "log", "RINT-86", "30", "--date", "2026-09-30", "--note", "x", "--timezone-offset-minutes", "-60" },
        .POST,
        "/mcp/time/log",
        "{\"task\":\"RINT-86\",\"minutes\":30,\"date\":\"2026-09-30\",\"timezone_offset_minutes\":-60,\"note\":\"x\"}",
    );
    try expectRequest(
        &.{ "time", "log", "RINT-86", "30" },
        .POST,
        "/mcp/time/log",
        "{\"task\":\"RINT-86\",\"minutes\":30}",
    );
    try expectRequest(
        &.{ "time", "log", "RINT-86", "30", "--note", "" },
        .POST,
        "/mcp/time/log",
        "{\"task\":\"RINT-86\",\"minutes\":30,\"note\":\"\"}",
    );
}

test "time update accepts note-only and date-only changes without minutes" {
    try expectRequest(
        &.{ "time", "update", "119", "--note", "x" },
        .POST,
        "/mcp/time/update",
        "{\"entry_id\":119,\"note\":\"x\"}",
    );
    try expectRequest(
        &.{ "time", "edit", "119", "--note", "" },
        .POST,
        "/mcp/time/update",
        "{\"entry_id\":119,\"note\":\"\"}",
    );
    try expectRequest(
        &.{ "time", "update", "119", "--date", "2026-09-30", "--timezone-offset-minutes", "-60" },
        .POST,
        "/mcp/time/update",
        "{\"entry_id\":119,\"date\":\"2026-09-30\",\"timezone_offset_minutes\":-60}",
    );
    try expectRequest(
        &.{ "time", "update", "119", "--minutes", "25", "--date", "2026-09-30", "--note", "corrected" },
        .POST,
        "/mcp/time/update",
        "{\"entry_id\":119,\"minutes\":25,\"date\":\"2026-09-30\",\"note\":\"corrected\"}",
    );
}

test "time mutations reject empty changes and metadata on negative corrections" {
    try expectDispatchError(error.InvalidOptions, &.{ "time", "update", "119" });
    try expectDispatchError(error.InvalidOptions, &.{ "time", "update", "119", "--timezone-offset-minutes", "-60" });
    try expectDispatchError(error.InvalidInteger, &.{ "time", "update", "119", "--minutes", "0", "--note", "x" });
    try expectDispatchError(error.InvalidInteger, &.{ "time", "log", "RINT-86", "0", "--note", "x" });
    try expectDispatchError(error.InvalidInteger, &.{ "time", "log", "RINT-86", "30", "--timezone-offset-minutes", "invalid" });
    for ([_][]const u8{ "--note", "--date", "--timezone-offset-minutes" }) |flag| {
        try expectDispatchError(error.InvalidOptions, &.{ "time", "log", "RINT-86", "-30", flag, "1" });
    }
}

test "router dispatches task and decision aliases" {
    try expectRequest(
        &.{ "task", "list", "--project", "15" },
        .GET,
        "/mcp/tasks?project_id=15&limit=10&offset=0",
        null,
    );
    try expectRequest(
        &.{ "tasks", "list", "--project", "15", "--filter", "section=AI Review", "--filter", "has_pr=red", "--fields", "title,url", "--limit", "20" },
        .GET,
        "/mcp/tasks?project_id=15&offset=0&fields=title%2Curl&limit=20&filter.section=AI%20Review&filter.has_pr=red",
        null,
    );
    try expectRequest(
        &.{ "tasks", "list", "--project", "15" },
        .GET,
        "/mcp/tasks?project_id=15&limit=10&offset=0",
        null,
    );
    try expectRequestCountWithResponses(
        &.{ "tasks", "list", "--project", "15", "--filter", "updated_since=2026-09-18T20:17:00Z" },
        &.{
            "{\"success\":true,\"tasks\":[{\"id\":4}],\"total\":2,\"limit\":100,\"offset\":0,\"nextCursor\":\"normal-cursor\"}",
            "{\"success\":true,\"tasks\":[{\"id\":3}],\"total\":2,\"limit\":100,\"offset\":0,\"nextCursor\":null}",
            "{\"success\":true,\"tasks\":[{\"id\":2}],\"total\":2,\"limit\":100,\"offset\":0,\"nextCursor\":\"archive-cursor\"}",
            "{\"success\":true,\"tasks\":[{\"id\":1}],\"total\":2,\"limit\":100,\"offset\":0,\"nextCursor\":null}",
        },
        4,
        .GET,
        "/mcp/tasks?project_id=15&limit=100&offset=0&filter.updated_since=2026-09-18T20%3A17%3A00Z&status=Archive&cursor=archive-cursor",
        null,
    );
    try expectRequestCountWithResponses(
        &.{ "tasks", "list", "--project", "15", "--filter", "updated_since=2026-09-18T20:17:00Z", "--filter", "status=Archive" },
        &.{"{\"success\":true,\"tasks\":[],\"total\":0,\"limit\":100,\"offset\":0,\"nextCursor\":null}"},
        1,
        .GET,
        "/mcp/tasks?project_id=15&limit=100&offset=0&filter.updated_since=2026-09-18T20%3A17%3A00Z&filter.status=Archive",
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

test "every HTPR-6530 list command forwards --limit" {
    try expectRequestWithResponses(
        &.{ "comment", "list", "HTPR-6530", "--limit", "3" },
        &.{"{\"success\":true,\"comments\":[],\"total\":0,\"offset\":0}"},
        .GET,
        "/mcp/comments?ticket_number=HTPR-6530&limit=3",
        null,
    );
    try expectRequestWithResponses(
        &.{ "comment", "list", "HTPR-6516", "--include-activity" },
        &.{"{\"success\":true,\"comments\":[],\"total\":0,\"offset\":0}"},
        .GET,
        "/mcp/comments?ticket_number=HTPR-6516&include_activity=true",
        null,
    );
    try expectRequest(
        &.{ "section", "list", "--project", "15", "--limit", "3" },
        .GET,
        "/mcp/projects/15/sections?limit=3",
        null,
    );
    try expectRequest(
        &.{ "labels", "list", "--project", "15", "--limit", "3" },
        .GET,
        "/mcp/projects/15/labels?limit=3",
        null,
    );
    try expectRequest(
        &.{ "agents", "list", "--management-key", "test-key", "--limit", "3" },
        .GET,
        "/mcp/admin/agents?limit=3",
        null,
    );
}

test "tasks list resolves --labels into a labels query filter" {
    try expectRequestWithResponses(
        &.{ "tasks", "list", "--project", "15", "--labels", "auto-error" },
        &.{"{\"labels\":[{\"id\":\"auto-error-label-id\",\"name\":\"auto-error\"}]}"},
        .GET,
        "/mcp/tasks?project_id=15&labels=auto-error-label-id&limit=10&offset=0",
        null,
    );
}

test "tasks list --label alias also filters" {
    try expectRequestWithResponses(
        &.{ "tasks", "list", "--project", "15", "--label", "auto-error" },
        &.{"{\"labels\":[{\"id\":\"auto-error-label-id\",\"name\":\"auto-error\"}]}"},
        .GET,
        "/mcp/tasks?project_id=15&labels=auto-error-label-id&limit=10&offset=0",
        null,
    );
}

test "task get distinguishes internal ids from project ticket indexes" {
    try expectRequestWithResponses(
        &.{ "tasks", "get", "5661", "--project", "15" },
        &.{
            "{\"success\":true,\"tasks\":[{\"id\":9001,\"projectId\":15}]}",
            "{\"success\":true,\"tasks\":[]}",
        },
        .GET,
        "/mcp/tasks?task_id=9001",
        null,
    );
    try expectRequestWithResponses(
        &.{ "tasks", "get", "40451", "--project", "15" },
        &.{
            "{\"success\":true,\"tasks\":[]}",
            "{\"success\":true,\"tasks\":[{\"id\":40451,\"projectId\":15}]}",
        },
        .GET,
        "/mcp/tasks?task_id=40451",
        null,
    );
    try expectDispatchErrorWithResponses(
        &.{ "tasks", "get", "5834", "--project", "15" },
        &.{
            "{\"success\":true,\"tasks\":[{\"id\":100,\"projectId\":15}]}",
            "{\"success\":true,\"tasks\":[{\"id\":200,\"projectId\":15}]}",
        },
        error.AmbiguousTaskIdentifier,
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
    try expectRequest(
        &.{ "tasks", "get", "6162" },
        .GET,
        "/mcp/tasks?task_id=6162",
        null,
    );
    try expectRequest(
        &.{ "comment", "add", "6162", "--text", "hi" },
        .POST,
        "/mcp/comments",
        "{\"task_id\":6162,\"text\":\"<p>hi</p>\"}",
    );
}

test "root create-board uses project validation and request routing" {
    const argv = [_][]const u8{ "--json", "create-board", "--title", "Pecunia", "--team", "team-1", "--description", "Finance board" };
    var parsed = try args.parse(std.testing.allocator, &argv);
    defer parsed.deinit();
    try @import("option_validate.zig").rejectUnknownOptions(std.testing.allocator, &parsed);
    try router.validateCommandPath(std.testing.allocator, parsed.positional, true);
    try expectRequest(
        &argv,
        .POST,
        "/mcp/teams/team-1/boards",
        "{\"title\":\"Pecunia\",\"sections\":[{\"title\":\"To Do\"},{\"title\":\"In Progress\"},{\"title\":\"Done\"}],\"description\":\"Finance board\"}",
    );
}

test "root create-board rejects undeclared options and extra arguments" {
    var unknown = try args.parse(std.testing.allocator, &.{ "create-board", "--typo", "value" });
    defer unknown.deinit();
    try std.testing.expectError(error.UnknownOption, @import("option_validate.zig").rejectUnknownOptions(std.testing.allocator, &unknown));
    var extra = try args.parse(std.testing.allocator, &.{ "create-board", "unexpected" });
    defer extra.deinit();
    try std.testing.expectError(error.InvalidOptions, router.validateCommandPath(std.testing.allocator, extra.positional, true));
}

test "project update sends the new title" {
    try expectRequest(
        &.{ "projects", "update", "5500", "--title", "Agent Toolkit" },
        .PATCH,
        "/mcp/projects/5500",
        "{\"title\":\"Agent Toolkit\"}",
    );
}

test "pages restore takes --version <id> instead of the global version switch" {
    try expectRequest(
        &.{ "pages", "restore", "642", "--version", "3427" },
        .POST,
        "/mcp/pages/restore",
        "{\"id\":642,\"version_id\":3427}",
    );
    try expectRequest(
        &.{ "pages", "restore", "--version", "3427", "642" },
        .POST,
        "/mcp/pages/restore",
        "{\"id\":642,\"version_id\":3427}",
    );
    try expectDispatchError(error.MissingOption, &.{ "pages", "restore", "642" });
}

test "project delete requires explicit confirmation" {
    try expectDispatchError(error.ConfirmationRequired, &.{ "projects", "delete", "15" });
}

test "task list accepts priority names" {
    try expectRequest(
        &.{ "task", "list", "--project", "15", "--priority", "high", "--limit", "1" },
        .GET,
        "/mcp/tasks?project_id=15&priority=2&offset=0&limit=1",
        null,
    );
}

test "task commands reject unknown priorities before making a request" {
    try expectDispatchError(error.InvalidOptions, &.{ "task", "list", "--project", "15", "--priority", "impossible", "--limit", "1" });
    try expectDispatchError(error.InvalidOptions, &.{ "task", "create", "--project", "15", "--title", "x", "--priority", "eventually" });
    try expectDispatchError(error.InvalidOptions, &.{ "task", "update", "HTPR-1", "--priority", "eventually" });
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

test "agents webhook compatibility path dispatches webhook commands" {
    try expectRequest(
        &.{ "agents", "webhook", "get" },
        .GET,
        "/mcp/webhooks?agent_id=self",
        null,
    );
    try expectRequest(
        &.{ "agents", "webhook", "configure", "--agent", "agent-1", "--event", "chat.message" },
        .POST,
        "/mcp/webhooks",
        "{\"action\":\"configure\",\"agent_id\":\"agent-1\",\"events\":[\"chat.message\"]}",
    );
    try expectRequest(
        &.{ "agents", "webhook", "rotate-secret", "--agent", "agent-1" },
        .POST,
        "/mcp/webhooks",
        "{\"action\":\"rotate\",\"agent_id\":\"agent-1\"}",
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
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"labels\":[{\"id\":\"qa-label-id\",\"name\":\"QA ✅\"}]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6234\",\"project_id\":15,\"add_labels\":[\"qa-label-id\"]}",
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6479", "--project", "15", "--add-label", "youtube" },
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"labels\":[{\"id\":\"youtube-id\",\"name\":\"youtube\"}]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6479\",\"project_id\":15,\"add_labels\":[\"youtube-id\"]}",
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6479", "--project", "15", "--labels", "youtube" },
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"labels\":[{\"id\":\"youtube-id\",\"name\":\"youtube\"}]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6479\",\"project_id\":15,\"labels\":[\"youtube-id\"]}",
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6234", "--project", "15", "--remove-labels", "11111111-2222-4333-8444-555555555555", "--add-labels", "CLI" },
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"labels\":[{\"id\":\"cli-label-id\",\"name\":\"CLI\"}]}", "{\"labels\":[]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6234\",\"project_id\":15,\"add_labels\":[\"cli-label-id\"],\"remove_labels\":[\"11111111-2222-4333-8444-555555555555\"]}",
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6479", "--project", "15", "--remove-label", "CLI" },
        &.{ "{\"tasks\":[{\"id\":35007,\"projectId\":15}]}", "{\"labels\":[{\"id\":\"cli-label-id\",\"name\":\"CLI\"}]}" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6479\",\"project_id\":15,\"remove_labels\":[\"cli-label-id\"]}",
    );
    try expectDispatchError(error.InvalidOptions, &.{ "task", "update", "HTPR-6479", "--labels", "youtube", "--add-label", "CLI" });
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
        &.{ "projects", "delete", "15", "--yes" },
        .POST,
        "/mcp/projects/archive",
        "{\"project_id\":15,\"status\":\"Deleted\"}",
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

test "task update claims and releases a lease after the server reports none" {
    try expectRequestCountWithResponses(
        &.{ "task", "update", "HTPR-5805", "--title", "Keep title" },
        &.{
            "{\"success\":false,\"tasks\":[],\"error\":\"Failed to update 1 task(s). Caller holds no agent mutation lease for this task. Claim one with POST /mcp/tasks/lease/claim before this write.\"}",
            "{\"success\":true,\"tasks\":[{\"id\":41043,\"projectId\":15}]}",
            "{\"success\":true,\"lease\":{\"taskId\":41043}}",
            "{\"success\":true,\"task\":{\"id\":41043,\"ticketNumber\":\"HTPR-5805\",\"projectId\":15}}",
            "{\"success\":true}",
        },
        5,
        .POST,
        "/mcp/tasks/lease/release",
        "{\"task_id\":41043}",
    );
}

test "comment reactions require an emoji" {
    try expectDispatchError(error.MissingOption, &.{ "comment", "react", "216402" });
    try expectDispatchError(error.MissingOption, &.{ "comment", "unreact", "216402" });
}

test "task update empty assignee or --clear-assignees unassigns through the assign route" {
    // Empty --assignee used to POST /mcp/tasks/update with no fields and get
    // missing_field. Assignee rows that agents created also survive assignee:[].
    // Clear by walking current rows through the existing unassign path.
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6519", "--assignee", "" },
        &.{ "{\"tasks\":[{\"id\":41043,\"assignees\":[]}]}", "{\"tasks\":[{\"id\":41043,\"assignees\":[]}]}" },
        .GET,
        "/mcp/tasks?ticket_number=HTPR-6519",
        null,
    );
    try expectRequestWithResponses(
        &.{ "task", "update", "HTPR-6519", "--clear-assignees" },
        &.{
            "{\"tasks\":[{\"id\":41043,\"assignees\":[{\"id\":6,\"agent\":{\"id\":\"agent-1\"}}]}]}",
            "{\"tasks\":[{\"id\":41043,\"assignees\":[{\"id\":6,\"agent\":{\"id\":\"agent-1\"}}]}]}",
            "{\"assignees\":[]}",
            "{\"tasks\":[{\"id\":41043,\"assignees\":[]}]}",
        },
        .GET,
        "/mcp/tasks?ticket_number=HTPR-6519",
        null,
    );
    try expectRequest(
        &.{ "task", "update", "HTPR-6519", "--assignee", "6,7" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6519\",\"assignee\":[6,7]}",
    );
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

test "comment add bare --improve posts the default rewrite" {
    try expectRequestCountWithResponses(
        &.{ "comment", "add", "HTPR-6574", "--improve", "--text", "<p>Draft</p>" },
        &.{
            "{\"tasks\":[{\"id\":42349,\"projectId\":15}]}",
            "{\"html\":\"<p>Improved readability</p>\"}",
            "{}",
        },
        3,
        .POST,
        "/mcp/comments",
        "{\"ticket_number\":\"HTPR-6574\",\"text\":\"<p>Improved readability</p>\"}",
    );
}

test "comment add --improve-command posts the requested rewrite" {
    try expectRequestCountWithResponses(
        &.{ "comment", "add", "HTPR-6574", "--improve", "--improve-command", "summarize", "--text", "<p>Draft</p>" },
        &.{
            "{\"tasks\":[{\"id\":42349,\"projectId\":15}]}",
            "{\"html\":\"<p>Summary</p>\"}",
            "{}",
        },
        3,
        .POST,
        "/mcp/comments",
        "{\"ticket_number\":\"HTPR-6574\",\"text\":\"<p>Summary</p>\"}",
    );
}

test "comment add and task descriptions wrap bare text in HTML paragraphs" {
    try expectRequest(
        &.{ "comment", "add", "HTPR-6501", "--text", "First paragraph\n\nSecond paragraph" },
        .POST,
        "/mcp/comments",
        "{\"ticket_number\":\"HTPR-6501\",\"text\":\"<p>First paragraph</p><p>Second paragraph</p>\"}",
    );
    try expectRequest(
        &.{ "task", "create", "--project", "15", "--title", "Wrapped", "--description", "First paragraph\n\nSecond paragraph" },
        .POST,
        "/mcp/tasks/create",
        "{\"project_id\":15,\"title\":\"Wrapped\",\"description\":\"<p>First paragraph</p><p>Second paragraph</p>\"}",
    );
    try expectRequest(
        &.{ "task", "update", "HTPR-6501", "--description", "First paragraph\n\nSecond paragraph" },
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6501\",\"description\":\"<p>First paragraph</p><p>Second paragraph</p>\"}",
    );
}

test "comment add and task descriptions keep leading HTML block tags" {
    try expectRequest(
        &.{ "comment", "add", "HTPR-6501", "--text", "<blockquote>Already HTML</blockquote>" },
        .POST,
        "/mcp/comments",
        "{\"ticket_number\":\"HTPR-6501\",\"text\":\"<blockquote>Already HTML</blockquote>\"}",
    );
    try expectRequest(
        &.{ "task", "create", "--project", "15", "--title", "HTML", "--description", "<h2>Already HTML</h2>" },
        .POST,
        "/mcp/tasks/create",
        "{\"project_id\":15,\"title\":\"HTML\",\"description\":\"<h2>Already HTML</h2>\"}",
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

test "pages update preserves type unless explicitly requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "report.html", .data = "<h1>Report</h1>" });
    const directory = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(directory);
    const path = try std.fs.path.join(std.testing.allocator, &.{ directory, "report.html" });
    defer std.testing.allocator.free(path);

    try expectRequest(
        &.{ "pages", "update", "265", "--markdown-file", path },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"content\":\"<h1>Report</h1>\",\"mode\":\"replace\"}",
    );
    try expectRequest(
        &.{ "pages", "update", "265", "--content", "<h1>Report</h1>", "--canvas" },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"content\":\"<h1>Report</h1>\",\"content_type\":\"html_canvas\",\"mode\":\"replace\"}",
    );
    try expectRequest(
        &.{ "pages", "update", "265", "--content", "<h1>Report</h1>", "--html" },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"content\":\"<h1>Report</h1>\",\"content_type\":\"html\",\"mode\":\"replace\"}",
    );
    try expectRequest(
        &.{ "pages", "update", "265", "--content", "# Report", "--markdown" },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"content\":\"# Report\",\"content_type\":\"markdown\",\"mode\":\"replace\"}",
    );
    try expectRequest(
        &.{ "pages", "update", "265", "--content", "# Report", "--mode", "prepend" },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"content\":\"# Report\",\"mode\":\"prepend\"}",
    );
    try expectRequest(
        &.{ "pages", "append", "265", "--content", "More" },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"content\":\"More\",\"mode\":\"append\"}",
    );
    try expectRequest(
        &.{ "pages", "update", "265", "--title", "Report" },
        .POST,
        "/mcp/pages/update",
        "{\"id\":265,\"title\":\"Report\"}",
    );
}

test "pages create keeps markdown default and explicit canvas" {
    try expectRequest(
        &.{ "pages", "create", "--task", "HTPR-6893", "--content", "# Report" },
        .POST,
        "/mcp/pages/create",
        "{\"ticket_number\":\"HTPR-6893\",\"content\":\"# Report\",\"content_type\":\"markdown\"}",
    );
    try expectRequest(
        &.{ "pages", "create", "--task", "HTPR-6893", "--content", "<h1>Report</h1>", "--canvas" },
        .POST,
        "/mcp/pages/create",
        "{\"ticket_number\":\"HTPR-6893\",\"content\":\"<h1>Report</h1>\",\"content_type\":\"html_canvas\"}",
    );
}

test "agents get reads one owned agent" {
    try expectRequest(
        &.{ "agents", "get", "--id", "a0e75f8c-9080-47bd-b09a-71c55bd34a87" },
        .GET,
        "/mcp/agents/a0e75f8c-9080-47bd-b09a-71c55bd34a87",
        null,
    );
    try expectRequest(
        &.{ "agents", "get", "a0e75f8c-9080-47bd-b09a-71c55bd34a87" },
        .GET,
        "/mcp/agents/a0e75f8c-9080-47bd-b09a-71c55bd34a87",
        null,
    );
    try expectDispatchError(error.MissingArgument, &.{ "agents", "get" });
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

test "agents update --name sends a display_name body" {
    try expectRequest(
        &.{ "agents", "update", "--id", "agent-1", "--name", "Ops Script" },
        .PATCH,
        "/mcp/agents/agent-1",
        "{\"display_name\":\"Ops Script\"}",
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
    try expectDispatchError(
        error.InvalidOptions,
        &.{ "agents", "update", "--id", "agent-1", "--visibility", "TEAM", "--name", "Ops Script" },
    );
}

test "agents update refuses to mix --name with project changes" {
    try expectDispatchError(
        error.InvalidOptions,
        &.{ "agents", "update", "--id", "agent-1", "--name", "Ops Script", "--add-project", "15" },
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

test "task update label catalog states replace vs add" {
    const catalog = @embedFile("capabilities.json");
    try std.testing.expect(std.mem.indexOf(u8, catalog, "Replace the ticket's entire label set") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "--add-label <list>") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "--remove-label <list>") != null);
}

test "update reuses ticket resolution for section and labels" {
    try expectRequestCountWithResponses(
        &.{ "task", "update", "HTPR-6805", "--section", "Done", "--labels", "CLI" },
        &.{
            "{\"tasks\":[{\"id\":35007,\"projectId\":101}]}",
            "{\"sections\":[{\"id\":2,\"section_title\":\"Done\"}]}",
            "{\"labels\":[{\"id\":\"cli-label-id\",\"name\":\"CLI\"}]}",
        },
        4,
        .POST,
        "/mcp/tasks/update",
        "{\"ticket_number\":\"HTPR-6805\",\"sectionId\":2,\"labels\":[\"cli-label-id\"]}",
    );
}

test "feedback posts default category and explicit metadata and note" {
    const response = "{\"success\":true,\"ticketNumber\":\"TEST-1\",\"url\":\"https://example.test/1\",\"deduped\":false,\"count\":1}";
    try expectRequestCountWithResponses(
        &.{ "feedback", "Unexpected failure" },
        &.{response},
        1,
        .POST,
        "/mcp/feedback",
        "{\"surface\":\"cli\",\"client\":\"hypertask-cli\",\"category\":\"other\",\"note\":\"Unexpected failure\"}",
    );
    try expectRequestCountWithResponses(
        &.{ "feedback", "Failed \"again\"\n", "--category", "call_failed", "--tool", "task get", "--status", "503", "--error-code", "upstream-error", "--error", "Unavailable", "--surface", "agent", "--json" },
        &.{response},
        1,
        .POST,
        "/mcp/feedback",
        "{\"surface\":\"agent\",\"client\":\"hypertask-cli\",\"category\":\"call_failed\",\"tool\":\"task get\",\"status\":503,\"errorCode\":\"upstream-error\",\"error\":\"Unavailable\",\"note\":\"Failed \\\"again\\\"\\n\"}",
    );
}

test "feedback accepts every category without a note" {
    const response = "{\"success\":true,\"ticketNumber\":\"TEST-1\",\"url\":\"https://example.test/1\",\"deduped\":false,\"count\":1}";
    try expectRequestCountWithResponses(
        &.{"feedback"},
        &.{response},
        1,
        .POST,
        "/mcp/feedback",
        "{\"surface\":\"cli\",\"client\":\"hypertask-cli\",\"category\":\"other\"}",
    );
    for ([_][]const u8{ "call_failed", "empty_result", "unexpected_result", "auth_failed", "slow", "user_reported_broken", "other" }) |category| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"surface\":\"cli\",\"client\":\"hypertask-cli\",\"category\":\"{s}\"}}", .{category});
        defer std.testing.allocator.free(body);
        try expectRequestCountWithResponses(&.{ "feedback", "--category", category }, &.{response}, 1, .POST, "/mcp/feedback", body);
    }
}

test "feedback rejects invalid category surface and status" {
    for ([_][]const u8{ "", "broken", "CALL_FAILED", "call-failed" }) |category| {
        try expectDispatchError(error.InvalidOptions, &.{ "feedback", "--category", category });
    }
    try expectDispatchError(error.InvalidOptions, &.{ "feedback", "failure", "--surface", "web" });
    for ([_][]const u8{ "abc", "99", "600", "-1" }) |status| {
        try expectDispatchError(error.InvalidInteger, &.{ "feedback", "failure", "--status", status });
    }
    try expectDispatchErrorWithResponses(&.{ "feedback", "failure" }, &.{"{\"success\":false,\"error\":\"not filed\"}"}, error.CommandFailed);
    try expectDispatchErrorWithResponses(&.{ "feedback", "failure" }, &.{"{}"}, error.InvalidResponse);
}

test "comment add sends each explicit kind and omits it by default" {
    for ([_][]const u8{ "question", "qa", "done" }) |kind| {
        const body = try std.fmt.allocPrint(std.testing.allocator, "{{\"ticket_number\":\"HTPR-7341\",\"text\":\"<p>Test</p>\",\"kind\":\"{s}\"}}", .{kind});
        defer std.testing.allocator.free(body);
        try expectRequest(
            &.{ "comment", "add", "HTPR-7341", "--text", "<p>Test</p>", "--kind", kind },
            .POST,
            "/mcp/comments",
            body,
        );
    }
    try expectRequestWithResponses(
        &.{ "comment", "add", "HTPR-7341", "--text", "<p>Test</p>" },
        &.{"{\"success\":true,\"comment\":{\"id\":1}}"},
        .POST,
        "/mcp/comments",
        "{\"ticket_number\":\"HTPR-7341\",\"text\":\"<p>Test</p>\"}",
    );
}

test "comment add rejects invalid kind before resolving or improving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "chatter", "Question", "" }) |kind| {
        var parsed = try args.parse(allocator, &.{ "comment", "add", "7341", "--project", "15", "--text", "Test", "--improve", "--kind", kind });
        defer parsed.deinit();
        var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
        defer cfg.deinit();
        var recorder = command_context.RequestRecorder.init(allocator);
        defer recorder.deinit();
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        const context = command_context.Context{
            .client = &client,
            .allocator = allocator,
            .args = &parsed,
            .cfg = &cfg,
            .json = true,
            .request_recorder = &recorder,
        };
        try std.testing.expectError(error.InvalidOptions, router.dispatch(&context));
        try std.testing.expectEqual(@as(usize, 0), recorder.responses_index);
        try std.testing.expect(recorder.method == null);
    }
}

test "search accepts projected rows without enrichment fields" {
    const cases = [_]struct { fields: []const u8, row: []const u8 }{
        .{ .fields = "title", .row = "{\"title\":\"Search\"}" },
        .{ .fields = "id,title", .row = "{\"id\":32507,\"title\":\"Search\"}" },
        .{ .fields = "description", .row = "{\"description\":\"\"}" },
        .{ .fields = "agent", .row = "{}" },
    };
    for (cases) |case| {
        const response = try std.fmt.allocPrint(std.testing.allocator, "{{\"success\":true,\"tasks\":[{s}],\"total\":1,\"boardId\":15,\"nextCursor\":null}}", .{case.row});
        defer std.testing.allocator.free(response);
        const path = try std.fmt.allocPrint(std.testing.allocator, "/mcp/tasks/search?q=search&limit=10&fields={s}", .{if (std.mem.eql(u8, case.fields, "id,title")) "id%2Ctitle" else case.fields});
        defer std.testing.allocator.free(path);
        try expectRequestCountWithResponses(
            &.{ "search", "search", "--fields", case.fields },
            &.{response},
            1,
            .GET,
            path,
            null,
        );
    }
}

test "search aliases honor projected fields" {
    const response = "{\"success\":true,\"tasks\":[{\"title\":\"Search\"}],\"total\":1,\"nextCursor\":null}";
    try expectRequestCountWithResponses(
        &.{ "tasks", "search", "search", "--fields", "title" },
        &.{response},
        1,
        .GET,
        "/mcp/tasks/search?q=search&limit=10&fields=title",
        null,
    );
    try expectRequestCountWithResponses(
        &.{ "tasks", "list", "--search", "search", "--fields", "title" },
        &.{response},
        1,
        .GET,
        "/mcp/tasks/search?q=search&limit=10&fields=title",
        null,
    );
}

test "search accepts empty results nullable metadata and unknown fields" {
    for ([_][]const u8{
        "{\"success\":true,\"tasks\":[],\"total\":0}",
        "{\"success\":true,\"tasks\":[],\"total\":0,\"nextCursor\":null}",
        "{\"success\":true,\"tasks\":[{\"id\":1,\"description\":\"Body\",\"ticketNumber\":null,\"dueDate\":null,\"type\":\"future-kind\"}],\"total\":1,\"nextCursor\":\"1\",\"partial\":true}",
    }) |response| {
        try expectRequestCountWithResponses(
            &.{ "search", "search" },
            &.{response},
            1,
            .GET,
            "/mcp/tasks/search?q=search&limit=10",
            null,
        );
    }
}

test "search rejects malformed response fields and API failure envelopes" {
    for ([_][]const u8{ "[]", "{}", "{\"tasks\":null}", "{\"tasks\":{}}", "{\"tasks\":[null]}", "{\"tasks\":[{\"id\":\"1\"}]}" }) |response| {
        try expectDispatchErrorWithResponses(&.{ "search", "search" }, &.{response}, error.InvalidResponse);
    }
    try expectDispatchErrorWithResponses(&.{ "search", "search", "--fields", "title" }, &.{"{\"tasks\":[null]}"}, error.InvalidResponse);
    try expectDispatchErrorWithResponses(&.{ "search", "search" }, &.{"{\"success\":false,\"error\":\"Search failed\"}"}, error.CommandFailed);
}

test "search still enriches unprojected empty descriptions" {
    for ([_][]const u8{ "", " , " }) |fields| {
        try expectRequestCountWithResponses(
            &.{ "search", "search", "--fields", fields },
            &.{
                "{\"success\":true,\"tasks\":[{\"id\":32507,\"ticketNumber\":\"HTPR-5658\",\"projectId\":15,\"description\":\"\"}],\"total\":1}",
                "{\"success\":true,\"tasks\":[{\"id\":32507,\"description\":\"Full description\"}]}",
            },
            2,
            .GET,
            "/mcp/tasks?task_id=32507",
            null,
        );
    }
}

const features_response =
    \\{"success":true,"scope":"Features available to this login","features":[{"key":"feature-without-name","description":"No destination yet.","shippedOn":"2026-01-01","available":true},{"key":"named-feature","name":"Views","url":"https://app.hypertask.ai/my-tasks","description":"Organize your work.","available":true},{"key":"core-inbox","name":"Inbox","url":"https://app.hypertask.ai/inbox","description":"Read your notifications.","available":true},{"key":"core-decisions","name":"Decisions","url":"https://app.hypertask.ai/inbox?split=Decisions","description":"Answer Question: mentions.","available":true},{"key":"nullable-feature","name":null,"url":null,"description":"Nullable metadata.","available":true}]}
;

fn expectFeaturesOutput(argv: []const []const u8, response: []const u8, status: std.http.Status, fetch_error: ?anyerror, expected_error: ?anyerror, expected_output: []const u8) !void {
    const posix = std.posix;
    const output = @import("output.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try args.parse(allocator, argv);
    defer parsed.deinit();
    try @import("option_validate.zig").rejectUnknownOptions(allocator, &parsed);
    try parsed.requireValues();
    try router.validateCommandPath(allocator, parsed.positional, true);
    var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
    defer cfg.deinit();
    var recorder = command_context.RequestRecorder.init(allocator);
    defer recorder.deinit();
    recorder.responses = &.{response};
    recorder.response_status = status;
    recorder.fetch_error = fetch_error;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = command_context.Context{
        .client = &client,
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = true,
        .request_recorder = &recorder,
    };

    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    {
        defer posix.close(pipe[1]);
        const saved_stdout = try posix.dup(1);
        defer posix.close(saved_stdout);
        try posix.dup2(pipe[1], 1);
        defer posix.dup2(saved_stdout, 1) catch {};
        const saved_stderr = try posix.dup(2);
        defer posix.close(saved_stderr);
        try posix.dup2(pipe[1], 2);
        defer posix.dup2(saved_stderr, 2) catch {};
        const result = router.dispatch(&context);
        result catch |err| output.printFailure(err);
        if (expected_error) |err| {
            try std.testing.expectError(err, result);
            try std.testing.expect(output.exitCode(err) != 0);
        } else {
            try result;
        }
    }
    var captured: [4096]u8 = undefined;
    const printed = try posix.read(pipe[0], &captured);
    try std.testing.expectEqualStrings(expected_output, captured[0..printed]);
    if (fetch_error == null) {
        try std.testing.expectEqual(@as(usize, 1), recorder.responses_index);
        try std.testing.expectEqual(std.http.Method.GET, recorder.method.?);
        try std.testing.expectEqualStrings("/mcp/features", recorder.path.?);
        try std.testing.expect(recorder.body == null);
    }
}

test "help features routes to live catalog and prints core destinations first" {
    try expectFeaturesOutput(&.{ "help", "features" }, features_response, .ok, null, null,
        \\Inbox: Read your notifications. (https://app.hypertask.ai/inbox)
        \\Decisions: Answer Question: mentions. (https://app.hypertask.ai/inbox?split=Decisions)
        \\feature-without-name: No destination yet.
        \\Views: Organize your work. (https://app.hypertask.ai/my-tasks)
        \\nullable-feature: Nullable metadata.
        \\
    );
}

test "help features json preserves the complete server response" {
    for ([_][]const []const u8{ &.{ "help", "features", "--json" }, &.{ "--json", "help", "features" } }) |argv| {
        try expectFeaturesOutput(argv, features_response, .ok, null, null, features_response ++ "\n");
    }
}

test "help features on an older server prints one clear line and fails" {
    for ([_][]const []const u8{ &.{ "help", "features" }, &.{ "help", "features", "--json" } }) |argv| {
        try expectFeaturesOutput(argv, "{\"success\":false,\"error\":\"Not found\"}", .not_found, null, error.FeaturesUnavailable,
            "hypertask: live features are unavailable on this server (GET /api/mcp/features returned 404); update the server\n");
    }
}

test "help features propagates transport failure instead of claiming an old server" {
    try expectFeaturesOutput(&.{ "help", "features" }, "", .ok, error.ConnectionRefused, error.ConnectionRefused,
        "hypertask: command failed (ConnectionRefused)\nNext: retry the same command once.\n");
}

test "help features retains the existing authentication failure path" {
    for ([_]std.http.Status{ .unauthorized, .forbidden }) |status| {
        try expectFeaturesOutput(&.{ "help", "features" }, "{\"success\":false,\"error\":\"Access denied\"}", status, null, error.ApiAuthentication,
            "{\"success\":false,\"error\":\"Access denied\"}\nhypertask: this token does not have the required access\nNext: ask the project owner to add this token.\n");
    }
}

test "help features rejects missing or unknown subcommands and extra arguments" {
    try std.testing.expectError(error.MissingSubcommand, router.validateCommandPath(std.testing.allocator, &.{"help"}, true));
    try std.testing.expectError(error.UnknownCommand, router.validateCommandPath(std.testing.allocator, &.{ "help", "unknown" }, true));
    try std.testing.expectError(error.InvalidOptions, router.validateCommandPath(std.testing.allocator, &.{ "help", "features", "extra" }, true));
    try expectDispatchError(error.UnknownCommand, &.{ "help", "unknown" });
}

test "top level and comment add help name the Decisions inbox" {
    const posix = std.posix;
    for ([_][]const []const u8{ &.{}, &.{ "comment", "add" }, &.{ "comments", "add" } }) |path| {
        const pipe = try posix.pipe();
        defer posix.close(pipe[0]);
        {
            defer posix.close(pipe[1]);
            const saved_stdout = try posix.dup(1);
            defer posix.close(saved_stdout);
            try posix.dup2(pipe[1], 1);
            defer posix.dup2(saved_stdout, 1) catch {};
            try router.printHelp(std.testing.allocator, path);
        }
        var captured: [8192]u8 = undefined;
        const printed = try posix.read(pipe[0], &captured);
        try std.testing.expect(std.mem.indexOf(u8, captured[0..printed], "A Question: comment that @mentions a person using a real mention shows up in their Inbox, split Decisions when enabled: https://app.hypertask.ai/inbox?split=Decisions.") != null);
        if (path.len == 0) try std.testing.expect(std.mem.indexOf(u8, captured[0..printed], "hypertask help features") != null);
    }
}
