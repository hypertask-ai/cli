const std = @import("std");
const Context = @import("../command_context.zig").Context;
const config = @import("../config.zig");
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const output = @import("../output.zig");

pub fn login(context: *const Context) !void {
    const login_token = context.args.get("token") orelse {
        output.fail("browser login is unavailable in hypertask; use `hypertask login --token <jwt>`");
    };
    try config.saveToken(context.allocator, login_token, context.args.get("api-url") orelse context.cfg.api_url);
    try output.print("{\"success\":true,\"saved\":true,\"configPath\":\"~/.hypertask/config.json\"}");
}

pub fn logout(context: *const Context) !void {
    if (context.args.get("token") != null) {
        try output.print("{\"success\":true,\"message\":\"Saved authentication unchanged\"}");
        return;
    }
    if (context.cfg.token.len != 0) {
        var response = http.request(context.allocator, context.cfg, .DELETE, "/mcp/token", null) catch null;
        if (response) |*value| value.deinit();
    }
    try config.clear(context.allocator);
    try output.print("{\"success\":true,\"message\":\"Logged out\"}");
}

pub fn status(context: *const Context) !void {
    var object = try json.Object.init(context.allocator);
    defer object.deinit();
    try object.boolean("authenticated", context.cfg.token.len != 0);
    try object.boolean("hasToken", context.cfg.token.len != 0);
    try object.string("apiUrl", context.cfg.api_url);
    const path = try config.configPath(context.allocator);
    try object.string("configPath", path);
    try output.print(try object.finish());
}

pub fn token(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "set-management-key")) {
        const key = try context.args.requirePositional(2, "key");
        if (!std.mem.startsWith(u8, key, "htmk_")) output.fail("management key must start with htmk_");
        try config.saveManagementKey(context.allocator, key);
        try output.print("{\"success\":true,\"saved\":true,\"configPath\":\"~/.hypertask/config.json\"}");
        return;
    }
    if (!std.mem.eql(u8, subcommand, "refresh")) output.fail("unknown token command");
    try context.requireAuth();
    var response = try http.request(context.allocator, context.cfg, .POST, "/mcp/token/refresh", null);
    defer response.deinit();
    const status_code = @intFromEnum(response.status);
    if (status_code < 200 or status_code >= 300) return output.finish(&response);

    var saved = false;
    if (context.args.get("token") == null and std.posix.getenv("HT_TOKEN") == null and std.posix.getenv("HYPERTASKS_JWT_TOKEN") == null) {
        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("token")) |token_value| if (token_value == .string) {
            try config.saveToken(context.allocator, token_value.string, context.cfg.api_url);
            saved = true;
        };
    }
    if (!saved) return output.print(response.body);

    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    var object = try json.Object.init(context.allocator);
    defer object.deinit();
    try object.boolean("success", true);
    if (parsed.value.object.get("token")) |value| if (value == .string) try object.string("token", value.string);
    if (parsed.value.object.get("expiresAt")) |value| if (value == .string) try object.string("expiresAt", value.string);
    try object.boolean("saved", true);
    try output.print(try object.finish());
}
