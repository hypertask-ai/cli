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

fn requestHeaders() std.http.Client.Request.Headers {
    return .{
        // Avoid std.http's automatic decompressor, whose fixed history buffer
        // can panic while rebasing a compressed response.
        .accept_encoding = .{ .override = "identity" },
    };
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

    // Drive the request manually instead of client.fetch: fetch's error
    // mapping unwraps a null body error on mid-body connection resets
    // (undefined behavior in ReleaseFast builds) and treats a clean early
    // close before Content-Length is satisfied as success, silently
    // returning a truncated body.
    const uri = try std.Uri.parse(url);
    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);
    var req = try client.request(method, uri, .{
        .redirect_behavior = if (payload == null) @enumFromInt(3) else .unhandled,
        .headers = requestHeaders(),
        .extra_headers = headers.headers[0..headers.count],
    });
    defer req.deinit();
    if (payload) |value| {
        req.transfer_encoding = .{ .content_length = value.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(value);
        try body_writer.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }
    var response = try req.receiveHead(redirect_buffer);
    const content_encoding = response.head.content_encoding;
    const expected_length = response.head.content_length;
    const decompress_buffer: []u8 = switch (content_encoding) {
        .identity => &.{},
        .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (decompress_buffer.len != 0) allocator.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    const written = reader.streamRemaining(&response_buffer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.HttpTransferFailed,
        else => |e| return e,
    };
    if (content_encoding == .identity) {
        if (expected_length) |expected| if (written < expected) return error.HttpRequestTruncated;
    }
    return .{
        .status = response.head.status,
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

test "requests opt out of automatic response decompression" {
    switch (requestHeaders().accept_encoding) {
        .override => |value| try std.testing.expectEqualStrings("identity", value),
        else => return error.UnexpectedAcceptEncoding,
    }
}
