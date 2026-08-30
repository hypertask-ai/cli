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
    const result = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |byte, index| result[index] = std.ascii.toUpper(byte);
    return result;
}

pub fn addTaskIdentifierQuery(path: *query_mod.Builder, allocator: std.mem.Allocator, identifier: []const u8) !void {
    if (isNumeric(identifier)) return path.add("task_id", identifier);
    const ticket = try normalizedTicket(allocator, identifier);
    defer allocator.free(ticket);
    try path.add("ticket_number", ticket);
}

pub fn addTaskIdentifierBody(body: *json.Object, allocator: std.mem.Allocator, identifier: []const u8) !void {
    if (isNumeric(identifier)) return body.integer("task_id", try common.positiveInt(identifier, "task-id"));
    const ticket = try normalizedTicket(allocator, identifier);
    defer allocator.free(ticket);
    try body.string("ticket_number", ticket);
}

pub fn task(context: *const Context, identifier: []const u8) !Task {
    if (isNumeric(identifier)) {
        return fetchTask(context, "task_id", identifier);
    }
    const ticket = try normalizedTicket(context.allocator, identifier);
    defer context.allocator.free(ticket);
    return fetchTask(context, "ticket_number", ticket);
}

fn fetchTask(context: *const Context, key: []const u8, value: []const u8) !Task {
    try context.requireAuth();
    var query = try query_mod.Builder.init(context.allocator, "/mcp/tasks");
    defer query.deinit();
    try query.add(key, value);
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

test "task identifier helpers distinguish numeric IDs from ticket keys" {
    var path = try query_mod.Builder.init(std.testing.allocator, "/mcp/drafts");
    defer path.deinit();
    try addTaskIdentifierQuery(&path, std.testing.allocator, "35341");
    try std.testing.expectEqualStrings("/mcp/drafts?task_id=35341", path.path());

    var numeric_body = try json.Object.init(std.testing.allocator);
    defer numeric_body.deinit();
    try addTaskIdentifierBody(&numeric_body, std.testing.allocator, "35341");
    try std.testing.expectEqualStrings("{\"task_id\":35341}", try numeric_body.finish());

    var ticket_body = try json.Object.init(std.testing.allocator);
    defer ticket_body.deinit();
    try addTaskIdentifierBody(&ticket_body, std.testing.allocator, "qaro2-8");
    try std.testing.expectEqualStrings("{\"ticket_number\":\"QARO2-8\"}", try ticket_body.finish());
}
