const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");
const resolve = @import("../resolve.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "create")) {
        const ticket = try context.args.requirePositional(2, "ticket");
        const options = try context.args.getAll(context.allocator, "option");
        if (options.len < 2 or options.len > 10) return error.InvalidOptions;
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("ticket_number", try resolve.normalizedTicket(context.allocator, ticket));
        try body.string("question", try context.args.require("question"));
        try body.strings("options", options);
        try context.call(.POST, "/mcp/decisions", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "list")) {
        const identifier = try context.args.requirePositional(2, "ticket-or-id");
        var path = try query.Builder.init(context.allocator, "/mcp/decisions");
        defer path.deinit();
        if (resolve.isNumeric(identifier)) try path.add("task_id", identifier) else try path.add("ticket_number", try resolve.normalizedTicket(context.allocator, identifier));
        if (context.args.get("status")) |value| try path.add("status", value);
        try context.call(.GET, path.path(), null);
    } else if (std.mem.eql(u8, subcommand, "get")) {
        const id = try context.args.requirePositional(2, "id");
        _ = try common.positiveInt(id, "id");
        try context.call(.GET, try std.fmt.allocPrint(context.allocator, "/mcp/decisions/{s}", .{id}), null);
    } else if (std.mem.eql(u8, subcommand, "answer") or std.mem.eql(u8, subcommand, "cancel")) {
        if (!context.args.has("confirm")) return error.ConfirmationRequired;
        const id = try context.args.requirePositional(2, "id");
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        if (std.mem.eql(u8, subcommand, "answer")) {
            try body.string("action", "answer");
            try body.string("selected_option", try context.args.require("option"));
            if (context.args.get("note")) |value| try body.string("note", value);
        } else try body.string("action", "cancel");
        try context.call(.PATCH, try std.fmt.allocPrint(context.allocator, "/mcp/decisions/{s}", .{id}), try body.finish());
    } else return error.UnknownCommand;
}
