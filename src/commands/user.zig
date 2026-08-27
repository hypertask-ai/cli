const std = @import("std");
const Context = @import("../command_context.zig").Context;
const json = @import("../json_util.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (!std.mem.eql(u8, subcommand, "update")) return error.UnknownCommand;
    if (context.args.get("name") == null and context.args.get("photo") == null) return error.MissingOption;
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    if (context.args.get("name")) |value| try body.string("displayName", value);
    if (context.args.get("photo")) |value| try body.string("photoURL", value);
    try context.call(.PATCH, "/mcp/user/profile", try body.finish());
}
