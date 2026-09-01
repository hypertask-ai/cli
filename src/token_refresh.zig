const std = @import("std");
const config = @import("config.zig");
const http = @import("http.zig");

const refresh_window_seconds: i64 = 7 * std.time.s_per_day;

const Dependencies = struct {
    fn request(_: *Dependencies, allocator: std.mem.Allocator, cfg: *const config.Config) !http.Response {
        return http.request(allocator, cfg, .POST, "/mcp/token/refresh", null);
    }

    fn persist(_: *Dependencies, allocator: std.mem.Allocator, token: []const u8, api_url: []const u8) !void {
        try config.saveToken(allocator, token, api_url);
    }
};

pub fn maybeRefresh(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    var dependencies = Dependencies{};
    try maybeRefreshWith(allocator, cfg, &dependencies, std.time.timestamp());
}

fn maybeRefreshWith(allocator: std.mem.Allocator, cfg: *config.Config, dependencies: anytype, now: i64) !void {
    _ = refreshCandidate(allocator, cfg, now) orelse return;

    var response = dependencies.request(allocator, cfg) catch return;
    defer response.deinit();
    const status_code = @intFromEnum(response.status);
    if (status_code < 200 or status_code >= 300) return;

    const RefreshBody = struct { token: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice(RefreshBody, allocator, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return;
    defer parsed.deinit();
    const token = parsed.value.token orelse return;
    if (token.len == 0) return;

    try dependencies.persist(allocator, token, cfg.api_url);
    try cfg.replaceToken(token);
}

const RefreshCandidate = struct {
    expires_at: i64,
};

fn refreshCandidate(allocator: std.mem.Allocator, cfg: *const config.Config, now: i64) ?RefreshCandidate {
    if (cfg.token_source != .saved) return null;

    var segments = std.mem.splitScalar(u8, cfg.token, '.');
    _ = segments.next() orelse return null;
    const encoded_payload = segments.next() orelse return null;
    _ = segments.next() orelse return null;
    if (segments.next() != null) return null;

    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded_payload) catch return null;
    const payload = allocator.alloc(u8, decoded_size) catch return null;
    defer allocator.free(payload);
    std.base64.url_safe_no_pad.Decoder.decode(payload, encoded_payload) catch return null;

    const Payload = struct {
        exp: ?i64 = null,
    };
    const parsed = std.json.parseFromSlice(Payload, allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const expires_at = parsed.value.exp orelse return null;
    if (expires_at > now + refresh_window_seconds) return null;
    return .{ .expires_at = expires_at };
}

fn testToken(allocator: std.mem.Allocator, expires_at: i64, has_jti: bool) ![]u8 {
    const payload = if (has_jti)
        try std.fmt.allocPrint(allocator, "{{\"exp\":{d},\"jti\":\"test-jti\"}}", .{expires_at})
    else
        try std.fmt.allocPrint(allocator, "{{\"exp\":{d}}}", .{expires_at});
    defer allocator.free(payload);
    const encoded_size = std.base64.url_safe_no_pad.Encoder.calcSize(payload.len);
    const encoded = try allocator.alloc(u8, encoded_size);
    defer allocator.free(encoded);
    const encoded_payload = std.base64.url_safe_no_pad.Encoder.encode(encoded, payload);
    return std.fmt.allocPrint(allocator, "e30.{s}.signature", .{encoded_payload});
}

const FakeDependencies = struct {
    allocator: std.mem.Allocator,
    request_count: usize = 0,
    persisted_token: ?[]u8 = null,

    fn deinit(self: *FakeDependencies) void {
        if (self.persisted_token) |token| self.allocator.free(token);
    }

    fn request(self: *FakeDependencies, allocator: std.mem.Allocator, _: *const config.Config) !http.Response {
        self.request_count += 1;
        return .{
            .status = .ok,
            .body = try allocator.dupe(u8, "{\"success\":true,\"token\":\"replacement-token\"}"),
            .allocator = allocator,
        };
    }

    fn persist(self: *FakeDependencies, _: std.mem.Allocator, token: []const u8, _: []const u8) !void {
        self.persisted_token = try self.allocator.dupe(u8, token);
    }
};

test "a saved token within seven days is refreshed and replaced before dispatch" {
    const now: i64 = 1_800_000_000;
    const token = try testToken(std.testing.allocator, now + refresh_window_seconds, true);
    defer std.testing.allocator.free(token);
    var cfg = config.Config{
        .allocator = std.testing.allocator,
        .token = token,
        .token_source = .saved,
    };
    defer cfg.deinit();
    var dependencies = FakeDependencies{ .allocator = std.testing.allocator };
    defer dependencies.deinit();

    try maybeRefreshWith(std.testing.allocator, &cfg, &dependencies, now);

    try std.testing.expectEqual(@as(usize, 1), dependencies.request_count);
    try std.testing.expectEqualStrings("replacement-token", dependencies.persisted_token.?);
    try std.testing.expectEqualStrings("replacement-token", cfg.token);
}

test "newer and non-saved tokens are not refreshed" {
    const now: i64 = 1_800_000_000;
    const newer_token = try testToken(std.testing.allocator, now + refresh_window_seconds + 1, true);
    defer std.testing.allocator.free(newer_token);
    var saved_cfg = config.Config{
        .allocator = std.testing.allocator,
        .token = newer_token,
        .token_source = .saved,
    };
    var saved_dependencies = FakeDependencies{ .allocator = std.testing.allocator };
    defer saved_dependencies.deinit();

    try maybeRefreshWith(std.testing.allocator, &saved_cfg, &saved_dependencies, now);
    try std.testing.expectEqual(@as(usize, 0), saved_dependencies.request_count);

    const expiring_token = try testToken(std.testing.allocator, now + refresh_window_seconds, true);
    defer std.testing.allocator.free(expiring_token);
    for ([_]config.TokenSource{ .environment, .argument }) |source| {
        var explicit_cfg = config.Config{
            .allocator = std.testing.allocator,
            .token = expiring_token,
            .token_source = source,
        };
        var explicit_dependencies = FakeDependencies{ .allocator = std.testing.allocator };
        defer explicit_dependencies.deinit();

        try maybeRefreshWith(std.testing.allocator, &explicit_cfg, &explicit_dependencies, now);
        try std.testing.expectEqual(@as(usize, 0), explicit_dependencies.request_count);
    }
}

test "a legacy saved token without jti is sent to the refresh endpoint" {
    const expires_at: i64 = 1_788_614_666;
    const token = try testToken(std.testing.allocator, expires_at, false);
    defer std.testing.allocator.free(token);
    var cfg = config.Config{
        .allocator = std.testing.allocator,
        .token = token,
        .token_source = .saved,
    };
    defer cfg.deinit();
    var dependencies = FakeDependencies{ .allocator = std.testing.allocator };
    defer dependencies.deinit();

    try maybeRefreshWith(std.testing.allocator, &cfg, &dependencies, expires_at - 60);

    try std.testing.expectEqual(@as(usize, 1), dependencies.request_count);
    try std.testing.expectEqualStrings("replacement-token", dependencies.persisted_token.?);
    try std.testing.expectEqualStrings("replacement-token", cfg.token);
}

test "a malformed saved token is not sent to the refresh endpoint" {
    var cfg = config.Config{
        .allocator = std.testing.allocator,
        .token = "not-a-jwt",
        .token_source = .saved,
    };
    var dependencies = FakeDependencies{ .allocator = std.testing.allocator };
    defer dependencies.deinit();

    try maybeRefreshWith(std.testing.allocator, &cfg, &dependencies, 1_800_000_000);
    try std.testing.expectEqual(@as(usize, 0), dependencies.request_count);
}
