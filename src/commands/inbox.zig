const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) return context.call(.GET, "/mcp/inbox/list", null);
    if (std.mem.eql(u8, subcommand, "composition")) {
        var path = try query.Builder.init(context.allocator, "/mcp/inbox/composition");
        defer path.deinit();
        try path.add("project_id", try context.args.require("project"));
        return context.call(.GET, path.path(), null);
    }
    if (std.mem.eql(u8, subcommand, "archive") or std.mem.eql(u8, subcommand, "unarchive")) {
        if (context.args.positional.len < 3) return error.MissingArgument;
        const ids = context.args.positional[2..];
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.integers("notification_ids", ids);
        return context.call(.POST, if (std.mem.eql(u8, subcommand, "archive")) "/mcp/inbox/archive" else "/mcp/inbox/unarchive", try body.finish());
    }
    return error.UnknownCommand;
}
