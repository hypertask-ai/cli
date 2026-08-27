const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    const token = common.managementToken(context);
    if (std.mem.eql(u8, subcommand, "list")) {
        try context.callWithToken(token, .GET, "/mcp/admin/agents", null);
    } else if (std.mem.eql(u8, subcommand, "create")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("display_name", try context.args.require("name"));
        const projects = try common.optionList(context, "project");
        if (projects.len != 0) try body.integers("project_ids", projects);
        try body.string("role", context.args.get("role") orelse "write");
        try context.callWithToken(token, .POST, "/mcp/admin/agents", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "revoke")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("agent_id", try context.args.require("id"));
        try context.callWithToken(token, .DELETE, "/mcp/admin/agents", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "rotate-token")) {
        const id = try context.args.require("id");
        const path = try std.fmt.allocPrint(context.allocator, "/mcp/admin/agents/{s}/token", .{id});
        try context.callWithToken(token, .POST, path, null);
    } else if (std.mem.eql(u8, subcommand, "rename")) {
        const id = try context.args.require("id");
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("display_name", try context.args.require("name"));
        const path = try std.fmt.allocPrint(context.allocator, "/mcp/agents/{s}", .{id});
        try context.callWithToken(token, .PATCH, path, try body.finish());
    } else return error.UnknownCommand;
}
