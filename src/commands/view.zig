const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) return list(context);
    const id = if (std.mem.eql(u8, subcommand, "create")) null else try context.args.requirePositional(2, "id");
    if (std.mem.eql(u8, subcommand, "get") or std.mem.eql(u8, subcommand, "show")) return context.call(.GET, try std.fmt.allocPrint(context.allocator, "/mcp/view/{s}", .{id.?}), null);
    if (std.mem.eql(u8, subcommand, "delete")) return context.call(.DELETE, try std.fmt.allocPrint(context.allocator, "/mcp/view/{s}", .{id.?}), null);
    if (std.mem.eql(u8, subcommand, "switch")) return context.call(.POST, try std.fmt.allocPrint(context.allocator, "/mcp/view/{s}/apply", .{id.?}), null);
    if (!std.mem.eql(u8, subcommand, "create") and !std.mem.eql(u8, subcommand, "update")) return error.UnknownCommand;
    var body = try viewBody(context, std.mem.eql(u8, subcommand, "create"));
    defer body.deinit();
    try context.call(if (id == null) .POST else .PATCH, if (id == null) "/mcp/view" else try std.fmt.allocPrint(context.allocator, "/mcp/view/{s}", .{id.?}), try body.finish());
}

fn list(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/view");
    defer path.deinit();
    if (context.args.get("project")) |value| try path.add("projectId", value);
    if (context.args.get("visibility")) |value| try path.add("visibility", value);
    try path.add("limit", context.args.get("limit") orelse "10");
    try path.add("offset", context.args.get("offset") orelse "0");
    try context.call(.GET, path.path(), null);
}

fn viewBody(context: *const Context, creating: bool) !json.Object {
    var body = try json.Object.init(context.allocator);
    if (context.args.get("project")) |value| try body.integer("project_id", try common.positiveInt(value, "project"));
    if (context.args.get("title")) |value| try body.string("title", value);
    if (context.args.get("visibility")) |value| try body.string("visibility", value);
    const labels = if (context.args.has("clear-labels")) @as([]const []const u8, &.{}) else try common.optionList(context, "label");
    const assignees = if (context.args.has("clear-assignees")) @as([]const []const u8, &.{}) else try common.optionList(context, "assignee");
    const has_filters = context.args.has("label") or context.args.has("assignee") or context.args.has("match") or context.args.has("clear-labels") or context.args.has("clear-assignees");
    if (has_filters and creating) {
        var filters = try json.Object.init(context.allocator);
        defer filters.deinit();
        if (context.args.has("label") or context.args.has("clear-labels")) try filters.strings("label_names", labels);
        if (context.args.has("assignee") or context.args.has("clear-assignees")) try filters.strings("assignee_ids", assignees);
        if (context.args.get("match")) |value| try filters.string("match", value);
        try body.raw("filters", try filters.finish());
    } else if (!creating) {
        if (context.args.has("label") or context.args.has("clear-labels")) try body.strings("label_names", labels);
        if (context.args.has("assignee") or context.args.has("clear-assignees")) try body.strings("assignee_ids", assignees);
        if (context.args.get("match")) |value| try body.string("match", value);
    }
    if (context.args.get("sort-mode")) |value| try body.string("sorting_mode", value);
    if (context.args.get("sort-order")) |value| try body.string("sorting_order", value);
    if (context.args.get("subtasks")) |value| try body.string("subtask_setting", value);
    if (context.args.has("default")) try body.boolean("set_as_default", true);
    return body;
}
