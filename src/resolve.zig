const std = @import("std");
const common = @import("command_context.zig");
const Context = common.Context;
const json = @import("json_util.zig");
const query_mod = @import("query.zig");

pub const Task = struct {
    id: i64,
    project_id: i64,
    ticket_number: ?[]const u8 = null,
    board: ?[]const u8 = null,
};

pub fn isNumeric(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

/// A task named as the positional or as `--task`, so one command shape reaches
/// the ticket either way (HTPR-8509). The positional wins when both are given,
/// as `comment list` has always done.
pub fn identifierArgument(context: *const Context, index: usize) ![]const u8 {
    if (context.args.positionalAt(index)) |positional| return positional;
    if (context.args.get("task")) |flag| return flag;
    std.debug.print("required argument: ticket-or-task-id (or --task <id-or-ticket>)\n", .{});
    return error.MissingArgument;
}

pub const internal_id_prefix = "id:";

/// An explicit internal task id, as printed in JSON output: `id:37799`.
pub fn internalId(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, internal_id_prefix)) return null;
    const digits = value[internal_id_prefix.len..];
    return if (isNumeric(digits)) digits else null;
}

pub fn normalizedTicket(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    const separator = std.mem.indexOfScalar(u8, trimmed, '-') orelse return error.InvalidTicket;
    if (separator == 0 or separator == trimmed.len - 1 or std.mem.indexOfScalar(u8, trimmed[separator + 1 ..], '-') != null) return error.InvalidTicket;
    if (!std.ascii.isAlphabetic(trimmed[0])) return error.InvalidTicket;
    for (trimmed[1..separator]) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidTicket;
    for (trimmed[separator + 1 ..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidTicket;

    const result = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |byte, index| result[index] = std.ascii.toUpper(byte);
    return result;
}

pub const TicketLink = struct {
    project: []const u8,
    number: []const u8,
};

/// A ticket link copied from the app, such as
/// https://app.hypertask.ai/detail/project-15/8341. The board and the ticket
/// number are the two path segments after /detail/.
pub fn ticketLink(value: []const u8) ?TicketLink {
    const marker = "/detail/";
    const start = (std.mem.indexOf(u8, value, marker) orelse return null) + marker.len;
    var path = value[start..];
    if (std.mem.indexOfAny(u8, path, "?#")) |end| path = path[0..end];
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return null;
    const board = path[0..slash];
    const tail = path[slash + 1 ..];
    const number = if (std.mem.indexOfScalar(u8, tail, '/')) |end| tail[0..end] else tail;
    if (!isNumeric(number)) return null;
    const dash = std.mem.indexOfScalar(u8, board, '-') orelse return null;
    if (dash == 0 or !isNumeric(board[dash + 1 ..])) return null;
    for (board[0..dash]) |byte| if (!std.ascii.isAlphabetic(byte)) return null;
    return .{ .project = board[dash + 1 ..], .number = number };
}

const IdentifierSink = union(enum) {
    query: *query_mod.Builder,
    body: *json.Object,

    fn string(self: IdentifierSink, name: []const u8, value: []const u8) !void {
        switch (self) {
            .query => |path| try path.add(name, value),
            .body => |body| try body.string(name, value),
        }
    }

    fn integer(self: IdentifierSink, name: []const u8, value: []const u8, label: []const u8) !void {
        const number = try common.positiveInt(value, label);
        switch (self) {
            .query => |path| try path.add(name, value),
            .body => |body| try body.integer(name, number),
        }
    }
};

pub fn addTaskIdentifierQuery(path: *query_mod.Builder, allocator: std.mem.Allocator, identifier: []const u8) !void {
    return addTaskIdentifierQueryForProject(path, allocator, identifier, null);
}

pub fn addTaskIdentifierQueryForProject(path: *query_mod.Builder, allocator: std.mem.Allocator, identifier: []const u8, project: ?[]const u8) !void {
    return addTaskIdentifier(.{ .query = path }, allocator, identifier, project);
}

pub fn addTaskIdentifierBody(body: *json.Object, allocator: std.mem.Allocator, identifier: []const u8) !void {
    return addTaskIdentifierBodyForProject(body, allocator, identifier, null);
}

pub fn addTaskIdentifierBodyForProject(body: *json.Object, allocator: std.mem.Allocator, identifier: []const u8, project: ?[]const u8) !void {
    return addTaskIdentifier(.{ .body = body }, allocator, identifier, project);
}

fn addTaskIdentifier(sink: IdentifierSink, allocator: std.mem.Allocator, identifier: []const u8, project: ?[]const u8) !void {
    if (ticketLink(identifier)) |link| {
        if (project) |project_id| {
            if (!std.mem.eql(u8, project_id, link.project)) return error.InvalidOptions;
        }
        try sink.integer("unique_index", link.number, "ticket");
        return sink.integer("project_id", link.project, "project");
    }
    if (internalId(identifier)) |task_id| return sink.integer("task_id", task_id, "task-id");
    if (isNumeric(identifier)) {
        const label = if (sink == .body and project != null) "ticket" else "task-id";
        if (project) |project_id| {
            try sink.integer("unique_index", identifier, label);
            return sink.integer("project_id", project_id, "project");
        }
        return sink.integer("task_id", identifier, label);
    }
    const ticket = try normalizedTicket(allocator, identifier);
    defer allocator.free(ticket);
    try sink.string("ticket_number", ticket);
    if (project) |project_id| try sink.integer("project_id", project_id, "project");
}

/// Resolve an identifier to one internal task. Bare digits without --project are
/// the list `id`, and name the ticket and board they landed on. With --project,
/// unique_index and task_id are both read; a collision or project mismatch fails closed.
pub fn task(context: *const Context, identifier: []const u8) !Task {
    if (ticketLink(identifier)) |link| {
        if (context.args.get("project")) |project| {
            if (!std.mem.eql(u8, project, link.project)) return error.InvalidOptions;
        }
        return resolveBareWithProject(context, link.number, link.project, try common.positiveInt(link.project, "project"));
    }
    if (internalId(identifier)) |task_id| return fetchTaskRequired(context, "task_id", task_id, null);
    if (isNumeric(identifier)) {
        _ = try common.positiveInt(identifier, "task-id");
        if (context.args.get("project")) |project| {
            const project_id = try common.positiveInt(project, "project");
            return resolveBareWithProject(context, identifier, project, project_id);
        }
        const found = fetchTaskRequired(context, "task_id", identifier, null) catch |err| {
            if (err == error.TaskNotFound) std.debug.print("{s}\n", .{try bareTaskIdMissNote(context.allocator, identifier)});
            return err;
        };
        std.debug.print("{s}\n", .{try bareTaskIdNote(context.allocator, identifier, found)});
        return found;
    }
    const ticket = try normalizedTicket(context.allocator, identifier);
    defer context.allocator.free(ticket);
    return fetchTaskRequired(context, "ticket_number", ticket, context.args.get("project"));
}

fn resolveBareWithProject(context: *const Context, identifier: []const u8, project: []const u8, project_id: i64) !Task {
    const by_index = try fetchTaskOptional(context, "unique_index", identifier, project);
    const by_id = try fetchTaskOptional(context, "task_id", identifier, null);

    const by_id_in_project: ?Task = if (by_id) |found|
        if (found.project_id == project_id) found else null
    else
        null;

    if (by_index) |index_task| {
        if (by_id_in_project) |id_task| {
            if (index_task.id != id_task.id) return collidingIdentifiers(identifier, project, index_task.id, id_task.id);
            return index_task;
        }
        return index_task;
    }
    if (by_id_in_project) |id_task| return id_task;
    if (by_id) |found| {
        std.debug.print(
            "{s} is task id {d} on project {d}, not project {s}\n",
            .{ identifier, found.id, found.project_id, project },
        );
        return error.InvalidProject;
    }
    return error.TaskNotFound;
}

fn collidingIdentifiers(identifier: []const u8, project: []const u8, unique_task_id: i64, list_task_id: i64) error{AmbiguousTaskIdentifier}!Task {
    std.debug.print(
        "{s} with --project {s} matches unique_index task id {d} and list id {d}; use PREFIX-{s} or id:{d}\n",
        .{ identifier, project, unique_task_id, list_task_id, identifier, list_task_id },
    );
    return error.AmbiguousTaskIdentifier;
}

fn fetchTaskRequired(context: *const Context, key: []const u8, value: []const u8, project: ?[]const u8) !Task {
    return (try fetchTaskOptional(context, key, value, project)) orelse error.TaskNotFound;
}

/// A bare number without --project is an internal task id, which can live on any board.
/// Naming the ticket and board keeps a wrong board visible instead of silent (HTPR-8423).
pub fn bareTaskIdNote(allocator: std.mem.Allocator, identifier: []const u8, found: Task) ![]u8 {
    return bareTaskIdNoteText(allocator, identifier, found.id, found.ticket_number, found.board);
}

fn bareTaskIdNoteText(allocator: std.mem.Allocator, identifier: []const u8, task_id: i64, ticket_number: ?[]const u8, board: ?[]const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} is task id {d}: {s} on {s}. A bare number is an internal id on any board; pass the ticket number, or --project with the board, when the board matters",
        .{ identifier, task_id, ticket_number orelse "an untitled task", board orelse "a board the token can see" },
    );
}

/// The same note from a read the command already made, so naming the ticket costs no second request.
pub fn bareTaskIdNoteFromResponse(allocator: std.mem.Allocator, identifier: []const u8, body: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const tasks = parsed.value.object.get("tasks") orelse return null;
    if (tasks != .array or tasks.array.items.len == 0) return null;
    const row = tasks.array.items[0];
    const task_id = json.integerField(row, "id", true) orelse return null;
    return try bareTaskIdNoteText(allocator, identifier, task_id, json.stringField(row, "ticketNumber"), json.stringField(row, "boardTitle"));
}

/// A bare number that is no task id is usually a ticket number on a board the
/// caller did not name, so say which flag reaches it (HTPR-8288).
pub fn bareTaskIdMissNote(allocator: std.mem.Allocator, identifier: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "no task has id {s}. A bare number is a task id on any board; pass the ticket key, or --project with the board, when it is a ticket number",
        .{identifier},
    );
}

/// The same note from a read the command already made, so a miss costs no second request.
pub fn bareTaskIdMissFromResponse(allocator: std.mem.Allocator, identifier: []const u8, body: []const u8) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("tasks")) |tasks| {
        if (tasks != .array or tasks.array.items.len != 0) return null;
    } else if (json.stringField(parsed.value, "error")) |error_text| {
        if (std.mem.indexOf(u8, error_text, "not found") == null) return null;
    } else return null;
    return try bareTaskIdMissNote(allocator, identifier);
}

fn ownedStringField(context: *const Context, row: std.json.Value, name: []const u8) !?[]const u8 {
    const value = json.stringField(row, name) orelse return null;
    return try context.allocator.dupe(u8, value);
}

/// Read-only lookup. Empty success payloads become null. Auth, 5xx, and other
/// transport failures propagate so callers never fall back after a soft error.
fn fetchTaskOptional(context: *const Context, key: []const u8, value: []const u8, project: ?[]const u8) !?Task {
    try context.requireAuth();
    var query = try query_mod.Builder.init(context.allocator, "/mcp/tasks");
    defer query.deinit();
    try query.add(key, value);
    if (project) |project_id| try query.add("project_id", project_id);
    var response = try context.fetchRaw(.GET, query.path(), null);
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code == 404) return null;
    if (!response.isSuccess()) return error.CommandFailed;
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("success")) |success| {
        if (success == .bool and success.bool == false) {
            if (parsed.value.object.get("error")) |err_value| {
                if (err_value == .string and std.mem.indexOf(u8, err_value.string, "not found") != null) return null;
            }
            return error.CommandFailed;
        }
    }
    const tasks = parsed.value.object.get("tasks") orelse return null;
    if (tasks != .array or tasks.array.items.len == 0) return null;
    const row = tasks.array.items[0];
    const id = json.integerField(row, "id", true) orelse return error.InvalidResponse;
    const project_id = json.integerField(row, "projectId", true) orelse json.integerField(row, "project_id", true) orelse return error.InvalidResponse;
    return .{
        .id = id,
        .project_id = project_id,
        .ticket_number = try ownedStringField(context, row, "ticketNumber"),
        .board = try ownedStringField(context, row, "boardTitle"),
    };
}

pub fn projectAccessDenied(project_id: i64) error{ProjectAccessDenied} {
    std.debug.print("this token is not a member of project {d}\n", .{project_id});
    return error.ProjectAccessDenied;
}

pub fn projectAccessDeniedResponse(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) bool {
    if (status == .forbidden) return true;
    const document = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer document.deinit();
    if (document.value != .object) return false;
    for ([_][]const u8{ "error", "message" }) |field| {
        const value = document.value.object.get(field) orelse continue;
        if (value != .string) continue;
        const message = std.mem.trim(u8, value.string, " \t\r\n");
        if (std.ascii.eqlIgnoreCase(message, "forbidden") or
            std.ascii.eqlIgnoreCase(message, "project not found or access denied")) return true;
    }
    return false;
}

pub fn sectionId(context: *const Context, project_id: i64, value: []const u8) !i64 {
    if (isNumeric(value)) return std.fmt.parseInt(i64, value, 10);
    try context.requireAuth();
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/sections", .{project_id});
    defer context.allocator.free(path);
    var response = try context.fetchRaw(.GET, path, null);
    defer response.deinit();
    if (projectAccessDeniedResponse(context.allocator, response.status, response.body)) return projectAccessDenied(project_id);
    if (!response.isSuccess()) return error.CommandFailed;
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const sections = parsed.value.object.get("sections") orelse return error.InvalidResponse;
    for (sections.array.items) |row| {
        const title_value = row.object.get("section_title") orelse continue;
        if (title_value != .string or !std.ascii.eqlIgnoreCase(title_value.string, value)) continue;
        return json.integerField(row, "id", true) orelse return error.InvalidResponse;
    }

    std.debug.print("section not found: {s}\nsections may only contain:", .{value});
    var first = true;
    for (sections.array.items) |row| {
        const title_value = row.object.get("section_title") orelse continue;
        if (title_value != .string) continue;
        std.debug.print("{s} {s}", .{ if (first) "" else ",", title_value.string });
        first = false;
    }
    std.debug.print("\n", .{});
    return error.SectionNotFound;
}

test "task identifier helpers normalize tickets and accept bare list ids" {
    var numeric_path = try query_mod.Builder.init(std.testing.allocator, "/mcp/drafts");
    defer numeric_path.deinit();
    try addTaskIdentifierQuery(&numeric_path, std.testing.allocator, "id:123");
    try std.testing.expectEqualStrings("/mcp/drafts?task_id=123", numeric_path.path());

    var bare_path = try query_mod.Builder.init(std.testing.allocator, "/mcp/drafts");
    defer bare_path.deinit();
    try addTaskIdentifierQuery(&bare_path, std.testing.allocator, "123");
    try std.testing.expectEqualStrings("/mcp/drafts?task_id=123", bare_path.path());

    var bare_body = try json.Object.init(std.testing.allocator);
    defer bare_body.deinit();
    try addTaskIdentifierBody(&bare_body, std.testing.allocator, "123");
    try std.testing.expectEqualStrings("{\"task_id\":123}", try bare_body.finish());

    var ticket_path = try query_mod.Builder.init(std.testing.allocator, "/mcp/drafts");
    defer ticket_path.deinit();
    try addTaskIdentifierQuery(&ticket_path, std.testing.allocator, "htpr-123");
    try std.testing.expectEqualStrings("/mcp/drafts?ticket_number=HTPR-123", ticket_path.path());

    var ticket_body = try json.Object.init(std.testing.allocator);
    defer ticket_body.deinit();
    try addTaskIdentifierBody(&ticket_body, std.testing.allocator, "HTPR-123");
    try std.testing.expectEqualStrings("{\"ticket_number\":\"HTPR-123\"}", try ticket_body.finish());

    var unique_path = try query_mod.Builder.init(std.testing.allocator, "/mcp/comments");
    defer unique_path.deinit();
    try addTaskIdentifierQueryForProject(&unique_path, std.testing.allocator, "5834", "15");
    try std.testing.expectEqualStrings("/mcp/comments?unique_index=5834&project_id=15", unique_path.path());

    var unique_body = try json.Object.init(std.testing.allocator);
    defer unique_body.deinit();
    try addTaskIdentifierBodyForProject(&unique_body, std.testing.allocator, "5834", "15");
    try std.testing.expectEqualStrings("{\"unique_index\":5834,\"project_id\":15}", try unique_body.finish());

    try std.testing.expectError(error.InvalidTicket, normalizedTicket(std.testing.allocator, "not-a-ticket"));
    try std.testing.expectError(error.InvalidTicket, normalizedTicket(std.testing.allocator, "123-4"));
}

test "a ticket link resolves like a ticket key" {
    const link = ticketLink("https://app.hypertask.ai/detail/project-15/8341").?;
    try std.testing.expectEqualStrings("15", link.project);
    try std.testing.expectEqualStrings("8341", link.number);

    const bare = ticketLink("/detail/project-15/8341#comment-77").?;
    try std.testing.expectEqualStrings("15", bare.project);
    try std.testing.expectEqualStrings("8341", bare.number);

    const deep = ticketLink("https://app.hypertask.ai/detail/project-4060/12/comments?tab=all").?;
    try std.testing.expectEqualStrings("4060", deep.project);
    try std.testing.expectEqualStrings("12", deep.number);

    try std.testing.expect(ticketLink("HTPR-8341") == null);
    try std.testing.expect(ticketLink("id:8341") == null);
    try std.testing.expect(ticketLink("/detail/project/8341") == null);
    try std.testing.expect(ticketLink("/detail/project-15/notanumber") == null);
    try std.testing.expect(ticketLink("/detail/-15/8341") == null);

    var link_path = try query_mod.Builder.init(std.testing.allocator, "/mcp/comments");
    defer link_path.deinit();
    try addTaskIdentifierQuery(&link_path, std.testing.allocator, "https://app.hypertask.ai/detail/project-15/8341");
    try std.testing.expectEqualStrings("/mcp/comments?unique_index=8341&project_id=15", link_path.path());

    var link_body = try json.Object.init(std.testing.allocator);
    defer link_body.deinit();
    try addTaskIdentifierBody(&link_body, std.testing.allocator, "https://app.hypertask.ai/detail/project-15/8341");
    try std.testing.expectEqualStrings("{\"unique_index\":8341,\"project_id\":15}", try link_body.finish());

    var same_project = try query_mod.Builder.init(std.testing.allocator, "/mcp/comments");
    defer same_project.deinit();
    try addTaskIdentifierQueryForProject(&same_project, std.testing.allocator, "https://app.hypertask.ai/detail/project-15/8341", "15");
    try std.testing.expectEqualStrings("/mcp/comments?unique_index=8341&project_id=15", same_project.path());

    var other_project = try query_mod.Builder.init(std.testing.allocator, "/mcp/comments");
    defer other_project.deinit();
    try std.testing.expectError(
        error.InvalidOptions,
        addTaskIdentifierQueryForProject(&other_project, std.testing.allocator, "https://app.hypertask.ai/detail/project-15/8341", "4060"),
    );
}

test "colliding bare identifiers refuse to guess" {
    try std.testing.expectError(
        error.AmbiguousTaskIdentifier,
        collidingIdentifiers("5834", "15", 100, 200),
    );
}

test "a bare task id names the ticket and board it resolved to" {
    const note = try bareTaskIdNote(std.testing.allocator, "908", .{
        .id = 908,
        .project_id = 55,
        .ticket_number = "sign-1",
        .board = "HT Design",
    });
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "908 is task id 908: sign-1 on HT Design. A bare number is an internal id on any board; pass the ticket number, or --project with the board, when the board matters",
        note,
    );
}

test "a task read names the ticket and board without a second request" {
    const body = "{\"success\":true,\"tasks\":[{\"id\":908,\"ticketNumber\":\"sign-1\",\"boardTitle\":\"HT Design\"}]}";
    const note = try bareTaskIdNoteFromResponse(std.testing.allocator, "908", body);
    defer if (note) |value| std.testing.allocator.free(value);
    try std.testing.expect(note != null);
    try std.testing.expectEqualStrings(
        "908 is task id 908: sign-1 on HT Design. A bare number is an internal id on any board; pass the ticket number, or --project with the board, when the board matters",
        note.?,
    );
    try std.testing.expect((try bareTaskIdNoteFromResponse(std.testing.allocator, "908", "not json")) == null);
    try std.testing.expect((try bareTaskIdNoteFromResponse(std.testing.allocator, "908", "{\"success\":false}")) == null);
}

test "a bare task id with no ticket or board still says where it landed" {
    const note = try bareTaskIdNote(std.testing.allocator, "908", .{ .id = 908, .project_id = 55 });
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "908 is task id 908: an untitled task on a board the token can see. A bare number is an internal id on any board; pass the ticket number, or --project with the board, when the board matters",
        note,
    );
}

test "a bare number that is no task id names the flags that reach it" {
    const note = try bareTaskIdMissNote(std.testing.allocator, "8288");
    defer std.testing.allocator.free(note);
    try std.testing.expectEqualStrings(
        "no task has id 8288. A bare number is a task id on any board; pass the ticket key, or --project with the board, when it is a ticket number",
        note,
    );
}

test "a task read that found nothing names the flags without a second request" {
    const missing = try bareTaskIdMissFromResponse(std.testing.allocator, "8288", "{\"success\":false,\"error\":\"Task not found or access denied\"}");
    defer if (missing) |value| std.testing.allocator.free(value);
    try std.testing.expect(missing != null);

    const empty = try bareTaskIdMissFromResponse(std.testing.allocator, "8288", "{\"success\":true,\"tasks\":[]}");
    defer if (empty) |value| std.testing.allocator.free(value);
    try std.testing.expect(empty != null);

    try std.testing.expect((try bareTaskIdMissFromResponse(std.testing.allocator, "8288", "{\"success\":true,\"tasks\":[{\"id\":908}]}")) == null);
    try std.testing.expect((try bareTaskIdMissFromResponse(std.testing.allocator, "8288", "{\"success\":false,\"error\":\"Unauthorized\"}")) == null);
    try std.testing.expect((try bareTaskIdMissFromResponse(std.testing.allocator, "8288", "not json")) == null);
}
