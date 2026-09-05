const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");
const query = @import("../query.zig");
const resolve = @import("../resolve.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) {
        var path = try query.Builder.init(context.allocator, "/mcp/custom-fields");
        defer path.deinit();
        try path.add("project_id", try context.args.require("project"));
        return context.call(.GET, path.path(), null);
    }
    if (std.mem.eql(u8, subcommand, "create")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.integer("project_id", try common.positiveInt(try context.args.require("project"), "project"));
        try body.string("name", try context.args.require("name"));
        if (context.args.get("type")) |value| try body.string("type", value);
        if (context.args.get("options")) |value| try body.raw("options", try normalizeOptions(context, value));
        return context.call(.POST, "/mcp/custom-fields", try body.finish());
    }
    if (std.mem.eql(u8, subcommand, "set")) {
        const task = try resolve.task(context, try context.args.requirePositional(2, "ticket-or-task-id"));
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.integer("task_id", task.id);
        try body.string("field_name", try context.args.require("name"));
        try body.string("value", try context.args.require("value"));
        return context.call(.POST, "/mcp/custom-fields/value", try body.finish());
    }
    if (std.mem.eql(u8, subcommand, "get")) {
        const ticket = try context.args.requirePositional(2, "ticket-or-task-id");
        var path = try query.Builder.init(context.allocator, "/mcp/tasks");
        defer path.deinit();
        try resolve.addTaskIdentifierQueryForProject(&path, context.allocator, ticket, context.args.get("project"));
        return context.call(.GET, path.path(), null);
    }
    if (std.mem.eql(u8, subcommand, "delete")) {
        const field_id = context.args.get("field-id") orelse try resolveFieldId(context);
        return context.call(.DELETE, try std.fmt.allocPrint(context.allocator, "/mcp/custom-fields/{s}", .{field_id}), null);
    }
    return error.UnknownCommand;
}

fn normalizeOptions(context: *const Context, raw: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidOptions;
    var result: std.ArrayListUnmanaged(u8) = .{};
    try result.append(context.allocator, '[');
    for (parsed.value.array.items, 0..) |item, index| {
        if (index != 0) try result.append(context.allocator, ',');
        if (item == .string) {
            var option = try json.Object.init(context.allocator);
            defer option.deinit();
            try option.string("id", item.string);
            try option.string("label", item.string);
            try result.appendSlice(context.allocator, try option.finish());
        } else try result.appendSlice(context.allocator, try std.json.Stringify.valueAlloc(context.allocator, item, .{}));
    }
    try result.append(context.allocator, ']');
    return result.toOwnedSlice(context.allocator);
}

fn resolveFieldId(context: *const Context) ![]const u8 {
    const project = try context.args.require("project");
    const name = try context.args.require("name");
    var path = try query.Builder.init(context.allocator, "/mcp/custom-fields");
    defer path.deinit();
    try path.add("project_id", project);
    var response = try http.get(context.allocator, context.cfg, path.path());
    defer response.deinit();
    if (@intFromEnum(response.status) < 200 or @intFromEnum(response.status) >= 300) {
        output.finish(&response) catch {};
        return error.CommandFailed;
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const fields = parsed.value.object.get("customFields") orelse return error.InvalidResponse;
    for (fields.array.items) |field| {
        const field_name = field.object.get("name") orelse continue;
        if (field_name == .string and std.ascii.eqlIgnoreCase(field_name.string, name)) {
            const id = field.object.get("id") orelse return error.InvalidResponse;
            if (id == .string) return context.allocator.dupe(u8, id.string);
        }
    }
    return error.FieldNotFound;
}
