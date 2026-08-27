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

    var headers: [3]std.http.Header = undefined;
    var count: usize = 2;
    headers[0] = .{ .name = "Authorization", .value = authorization };
    headers[1] = .{ .name = "X-CLI-Version", .value = "0.2.0-zig" };
    if (body != null) {
        headers[2] = .{ .name = "Content-Type", .value = "application/json" };
        count = 3;
    }

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = body,
        .extra_headers = headers[0..count],
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
