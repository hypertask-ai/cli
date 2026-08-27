const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const agents = @import("agents.zig");

pub fn run(context: *const Context, domain: []const u8, subcommand: []const u8) !void {
    if (std.mem.eql(u8, domain, "agents")) return agents.run(context, subcommand);
    const token = common.managementToken(context);
    if (std.mem.eql(u8, domain, "keys")) return keys(context, token, subcommand);
    if (std.mem.eql(u8, domain, "tokens")) return tokens(context, token, subcommand);
    if (std.mem.eql(u8, domain, "connections") and std.mem.eql(u8, subcommand, "list")) {
        return context.callWithToken(token, .GET, "/mcp/admin/connections", null);
    }
    return error.UnknownCommand;
}

fn keys(context: *const Context, token: []const u8, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) {
        try context.callWithToken(token, .GET, "/mcp/admin/keys", null);
    } else if (std.mem.eql(u8, subcommand, "create")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("name", try context.args.require("name"));
        try body.string("scope", context.args.get("scope") orelse "management");
        if (context.args.get("expires-in-days")) |value| try body.integer("expiresInDays", try common.positiveInt(value, "expires-in-days"));
        try context.callWithToken(token, .POST, "/mcp/admin/keys", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "revoke")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("keyId", try context.args.requirePositional(3, "keyId"));
        try context.callWithToken(token, .DELETE, "/mcp/admin/keys", try body.finish());
    } else return error.UnknownCommand;
}

fn tokens(context: *const Context, token: []const u8, subcommand: []const u8) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    if (std.mem.eql(u8, subcommand, "mint")) {
        const days = context.args.get("expires-in-days") orelse "30";
        try body.integer("expires_in_days", try common.positiveInt(days, "expires-in-days"));
        try context.callWithToken(token, .POST, "/mcp/admin/tokens", try body.finish());
    } else if (std.mem.eql(u8, subcommand, "revoke")) {
        if (context.args.has("all") == (context.args.get("account-token") != null)) return error.InvalidOptions;
        if (context.args.has("all")) try body.boolean("revoke_all", true) else try body.string("token", context.args.get("account-token").?);
        try context.callWithToken(token, .DELETE, "/mcp/admin/tokens", try body.finish());
    } else return error.UnknownCommand;
}
