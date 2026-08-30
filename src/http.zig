const std = @import("std");
const config = @import("config.zig");

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

const RequestHeaders = struct {
    headers: [4]std.http.Header,
    count: usize,
};

fn requestPayload(method: std.http.Method, body: ?[]const u8) ?[]const u8 {
    if (body) |value| return value;
    return if (method.requestHasBody()) "" else null;
}

fn buildRequestHeaders(authorization: []const u8, body: ?[]const u8) RequestHeaders {
    var result: RequestHeaders = undefined;
    result.headers[0] = .{ .name = "Authorization", .value = authorization };
    result.headers[1] = .{ .name = "X-CLI-Version", .value = "0.2.0-zig" };
    result.headers[2] = .{ .name = "User-Agent", .value = "htz/0.2.0" };
    result.count = 3;
    if (body != null) {
        result.headers[3] = .{ .name = "Content-Type", .value = "application/json" };
        result.count = 4;
    }
    return result;
}

pub fn request(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    method: std.http.Method,
    path_and_query: []const u8,
    body: ?[]const u8,
) !Response {
    return requestWithToken(allocator, cfg.api_url, cfg.token, method, path_and_query, body);
}

pub fn requestWithToken(
    allocator: std.mem.Allocator,
    api_url: []const u8,
    token: []const u8,
    method: std.http.Method,
    path_and_query: []const u8,
    body: ?[]const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ api_url, path_and_query });
    defer allocator.free(url);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);
    var response_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer response_buffer.deinit();

    const payload = requestPayload(method, body);
    const headers = buildRequestHeaders(authorization, payload);

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .extra_headers = headers.headers[0..headers.count],
        .response_writer = &response_buffer.writer,
    });
    return .{
        .status = result.status,
        .body = try allocator.dupe(u8, response_buffer.written()),
        .allocator = allocator,
    };
}

pub fn get(allocator: std.mem.Allocator, cfg: *const config.Config, path: []const u8) !Response {
    return request(allocator, cfg, .GET, path, null);
}

pub fn post(allocator: std.mem.Allocator, cfg: *const config.Config, path: []const u8, body: []const u8) !Response {
    return request(allocator, cfg, .POST, path, body);
}

pub fn put(allocator: std.mem.Allocator, cfg: *const config.Config, path: []const u8, body: []const u8) !Response {
    return request(allocator, cfg, .PUT, path, body);
}

pub fn patch(allocator: std.mem.Allocator, cfg: *const config.Config, path: []const u8, body: []const u8) !Response {
    return request(allocator, cfg, .PATCH, path, body);
}

pub fn delete(allocator: std.mem.Allocator, cfg: *const config.Config, path: []const u8, body: ?[]const u8) !Response {
    return request(allocator, cfg, .DELETE, path, body);
}

test "body-capable methods receive an empty payload instead of panicking" {
    try std.testing.expectEqualStrings("", requestPayload(.POST, null).?);
    try std.testing.expectEqualStrings("{}", requestPayload(.POST, "{}").?);
    try std.testing.expect(requestPayload(.GET, null) == null);
}

test "request headers identify htz with and without a JSON body" {
    const without_body = buildRequestHeaders("Bearer test", null);
    try std.testing.expectEqual(@as(usize, 3), without_body.count);
    try std.testing.expectEqualStrings("User-Agent", without_body.headers[2].name);
    try std.testing.expectEqualStrings("htz/0.2.0", without_body.headers[2].value);

    const with_body = buildRequestHeaders("Bearer test", "{}");
    try std.testing.expectEqual(@as(usize, 4), with_body.count);
    try std.testing.expectEqualStrings("User-Agent", with_body.headers[2].name);
    try std.testing.expectEqualStrings("htz/0.2.0", with_body.headers[2].value);
    try std.testing.expectEqualStrings("Content-Type", with_body.headers[3].name);
}
