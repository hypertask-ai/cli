const std = @import("std");

pub const Builder = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,
    has_query: bool = false,

    pub fn init(allocator: std.mem.Allocator, initial_path: []const u8) !Builder {
        var result = Builder{ .allocator = allocator };
        try result.buffer.appendSlice(allocator, initial_path);
        return result;
    }

    pub fn deinit(self: *Builder) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn add(self: *Builder, name: []const u8, value: []const u8) !void {
        try self.buffer.append(self.allocator, if (self.has_query) '&' else '?');
        self.has_query = true;
        try encode(&self.buffer, self.allocator, name);
        try self.buffer.append(self.allocator, '=');
        try encode(&self.buffer, self.allocator, value);
    }

    pub fn addInt(self: *Builder, name: []const u8, value: i64) !void {
        const formatted = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        defer self.allocator.free(formatted);
        try self.add(name, formatted);
    }

    pub fn path(self: *const Builder) []const u8 {
        return self.buffer.items;
    }
};

fn encode(buffer: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try buffer.append(allocator, byte);
        } else {
            try buffer.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0xf] });
        }
    }
}

test "query values are encoded" {
    var query = try Builder.init(std.testing.allocator, "/mcp/test");
    defer query.deinit();
    try query.add("team_id", "team/one");
    try std.testing.expectEqualStrings("/mcp/test?team_id=team%2Fone", query.path());
}
