const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    const agent = context.args.get("agent") orelse "self";
    if (std.mem.eql(u8, subcommand, "get") or std.mem.eql(u8, subcommand, "delete")) {
        if (std.mem.eql(u8, subcommand, "delete") and !context.args.has("confirm")) return error.ConfirmationRequired;
        var path = try query.Builder.init(context.allocator, "/mcp/webhooks");
        defer path.deinit();
        try path.add("agent_id", agent);
        try context.call(if (std.mem.eql(u8, subcommand, "get")) .GET else .DELETE, path.path(), null);
        return;
    }
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    if (std.mem.eql(u8, subcommand, "configure")) {
        try body.string("action", "configure");
        try body.string("agent_id", agent);
        if (context.args.get("url")) |value| try body.string("url", value);
        if (context.args.has("all-boards")) try body.nullValue("project_id") else if (context.args.get("project")) |value| try body.integer("project_id", try common.positiveInt(value, "project"));
        const events = try common.optionList(context, "event");
        if (events.len != 0) try body.strings("events", events);
        if (context.args.has("enabled")) try body.boolean("active", true);
        if (context.args.has("disabled")) try body.boolean("active", false);
    } else if (std.mem.eql(u8, subcommand, "test") or std.mem.eql(u8, subcommand, "replay") or std.mem.eql(u8, subcommand, "rotate-secret")) {
        const action = if (std.mem.eql(u8, subcommand, "rotate-secret")) "rotate" else subcommand;
        try body.string("action", action);
        try body.string("agent_id", agent);
        if (std.mem.eql(u8, subcommand, "replay")) try body.string("delivery_id", try context.args.requirePositional(2, "delivery-id"));
    } else return error.UnknownCommand;
    try context.call(.POST, "/mcp/webhooks", try body.finish());
}
