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
    try context.print("{\"success\":true,\"saved\":true,\"configPath\":\"~/.hypertask/config.json\"}");
}

pub fn logout(context: *const Context) !void {
    if (context.args.get("token") != null) {
        try context.print("{\"success\":true,\"message\":\"Saved authentication unchanged\"}");
        return;
    }
    if (context.cfg.token.len != 0) {
        var response = http.request(context.allocator, context.cfg, .DELETE, "/mcp/token", null) catch null;
        if (response) |*value| value.deinit();
    }
    try config.clear(context.allocator);
    try context.print("{\"success\":true,\"message\":\"Logged out\"}");
}

pub fn status(context: *const Context) !void {
    var object = try json.Object.init(context.allocator);
    defer object.deinit();
    try object.boolean("authenticated", context.cfg.token.len != 0);
    try object.boolean("hasToken", context.cfg.token.len != 0);
    try appendTokenIdentity(context.allocator, &object, context.cfg.token);
    try object.string("apiUrl", context.cfg.api_url);
    const path = try config.configPath(context.allocator);
    try object.string("configPath", path);
    try context.print(try object.finish());
}

fn appendTokenIdentity(allocator: std.mem.Allocator, object: *json.Object, token_value: []const u8) !void {
    var segments = std.mem.splitScalar(u8, token_value, '.');
    _ = segments.next() orelse return appendUnknownIdentity(object);
    const encoded_payload = segments.next() orelse return appendUnknownIdentity(object);
    _ = segments.next() orelse return appendUnknownIdentity(object);
    if (segments.next() != null) return appendUnknownIdentity(object);

    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded_payload) catch return appendUnknownIdentity(object);
    const payload = try allocator.alloc(u8, decoded_size);
    defer allocator.free(payload);
    std.base64.url_safe_no_pad.Decoder.decode(payload, encoded_payload) catch return appendUnknownIdentity(object);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return appendUnknownIdentity(object);
    defer parsed.deinit();
    if (parsed.value != .object) return appendUnknownIdentity(object);

    const agent_id = parsed.value.object.get("agentId");
    const is_agent = if (agent_id) |value| value == .string or value == .integer else false;
    try object.string("identity", if (is_agent) "agent" else "user");
    if (agent_id) |value| {
        switch (value) {
            .string => |id| try object.string("agentId", id),
            .integer => |id| try object.integer("agentId", id),
            else => try object.nullValue("agentId"),
        }
    } else {
        try object.nullValue("agentId");
    }

    const exp = parsed.value.object.get("exp");
    if (exp != null and exp.? == .integer) {
        if (try formatExpiry(allocator, exp.?.integer)) |formatted| {
            defer allocator.free(formatted);
            try object.string("expiresAt", formatted);
            return;
        }
    }
    try object.nullValue("expiresAt");
}

fn appendUnknownIdentity(object: *json.Object) !void {
    try object.string("identity", "user");
    try object.nullValue("agentId");
    try object.nullValue("expiresAt");
}

fn formatExpiry(allocator: std.mem.Allocator, seconds: i64) !?[]u8 {
    const unsigned = std.math.cast(u64, seconds) orelse return null;
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = unsigned };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    return try std.fmt.allocPrint(
        allocator,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
        },
    );
}

pub fn token(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "set-management-key")) {
        const key = try context.args.requirePositional(2, "key");
        if (!std.mem.startsWith(u8, key, "htmk_")) output.fail("management key must start with htmk_");
        try config.saveManagementKey(context.allocator, key);
        try context.print("{\"success\":true,\"saved\":true,\"configPath\":\"~/.hypertask/config.json\"}");
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
    if (!saved) return context.print(response.body);

    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    var object = try json.Object.init(context.allocator);
    defer object.deinit();
    try object.boolean("success", true);
    if (parsed.value.object.get("token")) |value| if (value == .string) try object.string("token", value.string);
    if (parsed.value.object.get("expiresAt")) |value| if (value == .string) try object.string("expiresAt", value.string);
    try object.boolean("saved", true);
    try context.print(try object.finish());
}
