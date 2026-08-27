const std = @import("std");
const Context = @import("../command_context.zig").Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "create")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("ticket_number", try context.args.requirePositional(2, "ticket"));
        try body.string("text", try context.args.require("text"));
        if (context.args.has("comment")) try body.string("draft_type", "comment");
        return context.call(.POST, "/mcp/drafts", try body.finish());
    }
    if (std.mem.eql(u8, subcommand, "list")) {
        var path = try query.Builder.init(context.allocator, "/mcp/drafts");
        defer path.deinit();
        try path.add("ticket_number", try context.args.requirePositional(2, "ticket"));
        return context.call(.GET, path.path(), null);
    }
    const id = try context.args.requirePositional(2, "draft-id");
    if (std.mem.eql(u8, subcommand, "update")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("text", try context.args.require("text"));
        return context.call(.PATCH, try std.fmt.allocPrint(context.allocator, "/mcp/drafts/{s}", .{id}), try body.finish());
    }
    if (std.mem.eql(u8, subcommand, "publish")) return context.call(.POST, try std.fmt.allocPrint(context.allocator, "/mcp/drafts/{s}/publish", .{id}), null);
    if (std.mem.eql(u8, subcommand, "delete")) return context.call(.DELETE, try std.fmt.allocPrint(context.allocator, "/mcp/drafts/{s}", .{id}), null);
    return error.UnknownCommand;
}
