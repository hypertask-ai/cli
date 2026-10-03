const std = @import("std");
const common = @import("command_context.zig");
const Context = common.Context;
const json = @import("json_util.zig");
const query_mod = @import("query.zig");

pub const Task = struct {
    id: i64,
    project_id: i64,
};

pub fn isNumeric(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
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
/// the list `id`. With --project, unique_index and task_id are both read; a
/// collision or project mismatch fails closed.
pub fn task(context: *const Context, identifier: []const u8) !Task {
    if (internalId(identifier)) |task_id| return fetchTaskRequired(context, "task_id", task_id, null);
    if (isNumeric(identifier)) {
        _ = try common.positiveInt(identifier, "task-id");
        if (context.args.get("project")) |project| {
            const project_id = try common.positiveInt(project, "project");
            return resolveBareWithProject(context, identifier, project, project_id);
        }
        return fetchTaskRequired(context, "task_id", identifier, null);
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
    return .{ .id = id, .project_id = project_id };
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

test "colliding bare identifiers refuse to guess" {
    try std.testing.expectError(
        error.AmbiguousTaskIdentifier,
        collidingIdentifiers("5834", "15", 100, 200),
    );
}
