const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const resolve = @import("../resolve.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    const project = try common.positiveInt(try context.args.require("project"), "project");
    if (std.mem.eql(u8, subcommand, "list")) {
        const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/sections", .{project});
        return context.call(.GET, path, null);
    }
    if (std.mem.eql(u8, subcommand, "create")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("title", try context.args.require("title"));
        if (context.args.get("after")) |value| try body.integer("after_section_id", try common.positiveInt(value, "after"));
        const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/sections", .{project});
        return context.call(.POST, path, try body.finish());
    }
    const section_value = try context.args.require("section");
    const section_id = try resolve.sectionId(context, project, section_value);
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/sections/{d}", .{ project, section_id });
    if (std.mem.eql(u8, subcommand, "delete")) return context.call(.DELETE, path, null);
    if (std.mem.eql(u8, subcommand, "update")) {
        var update_body = try json.Object.init(context.allocator);
        defer update_body.deinit();
        const auto_assign = try context.args.require("auto-assign");
        if (std.mem.eql(u8, auto_assign, "none")) {
            try update_body.nullValue("auto_assign");
        } else if (resolve.isNumeric(auto_assign)) {
            try update_body.integer("auto_assign", try common.positiveInt(auto_assign, "auto-assign"));
        } else {
            try update_body.string("auto_assign", auto_assign);
        }
        return context.call(.PATCH, path, try update_body.finish());
    }
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    if (std.mem.eql(u8, subcommand, "rename")) {
        try body.string("title", try context.args.require("title"));
    } else if (std.mem.eql(u8, subcommand, "reorder")) {
        const after = try resolve.sectionId(context, project, try context.args.require("after"));
        if (after == section_id) return error.InvalidOptions;
        try body.integer("move_after_section_id", after);
    } else if (std.mem.eql(u8, subcommand, "done")) {
        if (context.args.has("off") and context.args.has("clear")) return error.InvalidOptions;
        if (context.args.has("clear")) try body.nullValue("is_done") else try body.boolean("is_done", !context.args.has("off"));
    } else return error.UnknownCommand;
    try context.call(.PATCH, path, try body.finish());
}
