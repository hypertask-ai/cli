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
    const url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ api_url, path_and_query });
    defer allocator.free(url);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
    defer allocator.free(authorization);
    const headers = buildRequestHeaders(authorization, requestPayload(method, body));
    return send(allocator, method, url, headers.headers[0..headers.count], body);
}

fn effectivePort(uri: std.Uri) ?u16 {
    if (uri.port) |port| return port;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return 80;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return 443;
    return null;
}

fn sameOrigin(a: std.Uri, b: std.Uri) !bool {
    if (!std.ascii.eqlIgnoreCase(a.scheme, b.scheme)) return false;
    if (effectivePort(a) != effectivePort(b)) return false;

    var a_host_buffer: [std.Uri.host_name_max]u8 = undefined;
    var b_host_buffer: [std.Uri.host_name_max]u8 = undefined;
    const a_host = try a.getHost(&a_host_buffer);
    const b_host = try b.getHost(&b_host_buffer);
    return std.ascii.eqlIgnoreCase(a_host, b_host);
}

fn isHttpsDowngrade(from: std.Uri, to: std.Uri) bool {
    return std.ascii.eqlIgnoreCase(from.scheme, "https") and
        std.ascii.eqlIgnoreCase(to.scheme, "http");
}

fn withoutAuthorization(headers: []const std.http.Header, buffer: []std.http.Header) []const std.http.Header {
    var count: usize = 0;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Authorization")) continue;
        buffer[count] = header;
        count += 1;
    }
    return buffer[0..count];
}

/// Drive one request against an absolute URL with caller-owned headers. The
/// Hypertask bearer token is never added here, so a command can post to a
/// handler running on the author's own machine without leaking credentials.
pub fn send(
    allocator: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    extra_headers: []const std.http.Header,
    body: ?[]const u8,
) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var response_buffer: std.Io.Writer.Allocating = .init(allocator);
    defer response_buffer.deinit();

    const payload = requestPayload(method, body);
    const original_uri = try std.Uri.parse(url);
    var current_url = try allocator.dupe(u8, url);
    defer allocator.free(current_url);
    const redirect_buffer = try allocator.alloc(u8, 8 * 1024);
    defer allocator.free(redirect_buffer);
    const filtered_headers = try allocator.alloc(std.http.Header, extra_headers.len);
    defer allocator.free(filtered_headers);
    var redirects_remaining: u16 = 3;

    while (true) {
        const uri = try std.Uri.parse(current_url);
        const request_extra_headers = if (try sameOrigin(original_uri, uri))
            extra_headers
        else
            withoutAuthorization(extra_headers, filtered_headers);

        // Drive the request manually instead of client.fetch: fetch's error
        // mapping unwraps a null body error on mid-body connection resets
        // (undefined behavior in ReleaseFast builds) and treats a clean early
        // close before Content-Length is satisfied as success, silently
        // returning a truncated body.
        const next_url: ?[]u8 = request: {
            var req = try client.request(method, uri, .{
                .redirect_behavior = .unhandled,
                .headers = requestHeaders(),
                .extra_headers = request_extra_headers,
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
            var response = try req.receiveHead(&.{});

            if (payload == null and method != .HEAD and response.head.status.class() == .redirect and
                response.head.status != .not_modified)
            {
                if (redirects_remaining == 0) return error.TooManyHttpRedirects;
                const location = response.head.location orelse return error.HttpRedirectLocationMissing;
                if (location.len > redirect_buffer.len) return error.HttpRedirectLocationOversize;
                @memcpy(redirect_buffer[0..location.len], location);
                var unused_redirect_buffer = redirect_buffer;
                const next_uri = uri.resolveInPlace(location.len, &unused_redirect_buffer) catch |err| switch (err) {
                    error.UnexpectedCharacter, error.InvalidFormat, error.InvalidPort => return error.HttpRedirectLocationInvalid,
                    error.NoSpaceLeft => return error.HttpRedirectLocationOversize,
                };
                if (isHttpsDowngrade(uri, next_uri)) return error.HttpRedirectDowngrade;
                const resolved_url = try std.fmt.allocPrint(allocator, "{f}", .{next_uri.fmt(.all)});
                errdefer allocator.free(resolved_url);

                var discard_buffer: [64]u8 = undefined;
                const redirect_reader = response.reader(&discard_buffer);
                _ = redirect_reader.discardRemaining() catch |err| switch (err) {
                    error.ReadFailed => return response.bodyErr() orelse error.HttpTransferFailed,
                };
                break :request resolved_url;
            }

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
        };

        allocator.free(current_url);
        current_url = next_url.?;
        redirects_remaining -= 1;
    }
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

test "redirect origins include scheme host and effective port" {
    const original = try std.Uri.parse("https://example.com/path");
    try std.testing.expect(try sameOrigin(original, try std.Uri.parse("https://EXAMPLE.com:443/next")));
    try std.testing.expect(!try sameOrigin(original, try std.Uri.parse("https://example.com:444/next")));
    try std.testing.expect(!try sameOrigin(original, try std.Uri.parse("https://other.example.com/next")));
    try std.testing.expect(!try sameOrigin(original, try std.Uri.parse("http://example.com/next")));
}

test "HTTPS redirects cannot downgrade to HTTP" {
    const https = try std.Uri.parse("https://example.com/start");
    const http = try std.Uri.parse("http://example.com/next");
    try std.testing.expect(isHttpsDowngrade(https, http));
    try std.testing.expect(!isHttpsDowngrade(http, https));
}
