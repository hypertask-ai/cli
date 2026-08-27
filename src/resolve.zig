const std = @import("std");
const Context = @import("command_context.zig").Context;
const http = @import("http.zig");
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
