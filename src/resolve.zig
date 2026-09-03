const std = @import("std");
const common = @import("command_context.zig");
const Context = common.Context;
const http = @import("http.zig");
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

pub fn addTaskIdentifierQuery(path: *query_mod.Builder, allocator: std.mem.Allocator, identifier: []const u8) !void {
    return addTaskIdentifierQueryForProject(path, allocator, identifier, null);
}

pub fn addTaskIdentifierQueryForProject(path: *query_mod.Builder, allocator: std.mem.Allocator, identifier: []const u8, project: ?[]const u8) !void {
    if (isNumeric(identifier)) {
        if (project) |project_id| {
            _ = try common.positiveInt(identifier, "ticket");
            _ = try common.positiveInt(project_id, "project");
            try path.add("unique_index", identifier);
            return path.add("project_id", project_id);
        }
        return path.add("task_id", identifier);
    }
    const ticket = try normalizedTicket(allocator, identifier);
    defer allocator.free(ticket);
    try path.add("ticket_number", ticket);
    if (project) |project_id| {
        _ = try common.positiveInt(project_id, "project");
        try path.add("project_id", project_id);
    }
}

pub fn addTaskIdentifierBody(body: *json.Object, allocator: std.mem.Allocator, identifier: []const u8) !void {
    return addTaskIdentifierBodyForProject(body, allocator, identifier, null);
}

pub fn addTaskIdentifierBodyForProject(body: *json.Object, allocator: std.mem.Allocator, identifier: []const u8, project: ?[]const u8) !void {
    if (isNumeric(identifier)) {
        if (project) |project_id| {
            try body.integer("unique_index", try common.positiveInt(identifier, "ticket"));
            return body.integer("project_id", try common.positiveInt(project_id, "project"));
        }
        return body.integer("task_id", try common.positiveInt(identifier, "task-id"));
    }
    const ticket = try normalizedTicket(allocator, identifier);
    defer allocator.free(ticket);
    try body.string("ticket_number", ticket);
    if (project) |project_id| try body.integer("project_id", try common.positiveInt(project_id, "project"));
}

pub fn task(context: *const Context, identifier: []const u8) !Task {
    if (isNumeric(identifier)) {
        if (context.args.get("project")) |project| {
            return fetchTask(context, "unique_index", identifier, project);
        }
        return fetchTask(context, "task_id", identifier, null);
    }
    const ticket = try normalizedTicket(context.allocator, identifier);
    defer context.allocator.free(ticket);
    return fetchTask(context, "ticket_number", ticket, context.args.get("project"));
}

fn fetchTask(context: *const Context, key: []const u8, value: []const u8, project: ?[]const u8) !Task {
    try context.requireAuth();
    var query = try query_mod.Builder.init(context.allocator, "/mcp/tasks");
    defer query.deinit();
    try query.add(key, value);
    if (project) |project_id| try query.add("project_id", project_id);
    var response = try http.get(context.allocator, context.cfg, query.path());
    defer response.deinit();
    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) return error.CommandFailed;
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const tasks = parsed.value.object.get("tasks") orelse return error.TaskNotFound;
    if (tasks != .array or tasks.array.items.len == 0) return error.TaskNotFound;
    const row = tasks.array.items[0];
    const id = jsonInteger(row, "id") orelse return error.InvalidResponse;
    const project_id = jsonInteger(row, "projectId") orelse jsonInteger(row, "project_id") orelse return error.InvalidResponse;
    return .{ .id = id, .project_id = project_id };
}

fn jsonInteger(value: std.json.Value, key: []const u8) ?i64 {
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

pub fn sectionId(context: *const Context, project_id: i64, value: []const u8) !i64 {
    if (isNumeric(value)) return std.fmt.parseInt(i64, value, 10);
    try context.requireAuth();
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/sections", .{project_id});
    defer context.allocator.free(path);
    var response = try http.get(context.allocator, context.cfg, path);
    defer response.deinit();
    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) return error.CommandFailed;
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const sections = parsed.value.object.get("sections") orelse return error.InvalidResponse;
    for (sections.array.items) |row| {
        const title_value = row.object.get("section_title") orelse continue;
        if (title_value != .string or !std.ascii.eqlIgnoreCase(title_value.string, value)) continue;
        return jsonInteger(row, "id") orelse return error.InvalidResponse;
    }
    return error.SectionNotFound;
}

test "task identifier helpers normalize tickets and reject invalid values" {
    var numeric_path = try query_mod.Builder.init(std.testing.allocator, "/mcp/drafts");
    defer numeric_path.deinit();
    try addTaskIdentifierQuery(&numeric_path, std.testing.allocator, "123");
    try std.testing.expectEqualStrings("/mcp/drafts?task_id=123", numeric_path.path());

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
