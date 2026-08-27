const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "running")) return context.call(.GET, "/mcp/time/running", null);
    if (std.mem.eql(u8, subcommand, "report")) return report(context);
    const valid = std.mem.eql(u8, subcommand, "start") or std.mem.eql(u8, subcommand, "stop") or std.mem.eql(u8, subcommand, "pause") or std.mem.eql(u8, subcommand, "resume") or std.mem.eql(u8, subcommand, "status") or std.mem.eql(u8, subcommand, "log");
    if (!valid) return error.UnknownCommand;
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("task", try context.args.requirePositional(2, "task"));
    if (std.mem.eql(u8, subcommand, "log")) try body.integer("minutes", try common.positiveInt(try context.args.requirePositional(3, "minutes"), "minutes"));
    try context.call(.POST, try std.fmt.allocPrint(context.allocator, "/mcp/time/{s}", .{subcommand}), try body.finish());
}

fn report(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/time/report");
    defer path.deinit();
    const fields = [_][]const u8{ "board", "task", "user", "from", "to" };
    for (fields) |field| if (context.args.get(field)) |value| try path.add(field, value);
    if (context.args.has("running")) try path.add("running", "1");
    try context.call(.GET, path.path(), null);
}
