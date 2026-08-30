const std = @import("std");

pub fn writeString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (byte < 0x20) {
                const hex = "0123456789abcdef";
                const escaped = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0xf] };
                try writer.writeAll(&escaped);
            } else try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

pub const Object = struct {
    buffer: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,
    first: bool = true,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Object {
        var result = Object{ .allocator = allocator };
        try result.buffer.append(allocator, '{');
        return result;
    }

    pub fn deinit(self: *Object) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    fn key(self: *Object, name: []const u8) !void {
        if (!self.first) try self.buffer.append(self.allocator, ',');
        self.first = false;
        const writer = self.buffer.writer(self.allocator);
        try writeString(writer, name);
        try self.buffer.append(self.allocator, ':');
    }

    pub fn string(self: *Object, name: []const u8, value: []const u8) !void {
        try self.key(name);
        try writeString(self.buffer.writer(self.allocator), value);
    }

    pub fn raw(self: *Object, name: []const u8, value: []const u8) !void {
        try self.key(name);
        try self.buffer.appendSlice(self.allocator, value);
    }

    pub fn integer(self: *Object, name: []const u8, value: i64) !void {
        try self.key(name);
        try self.buffer.writer(self.allocator).print("{d}", .{value});
    }

    pub fn boolean(self: *Object, name: []const u8, value: bool) !void {
        try self.raw(name, if (value) "true" else "false");
    }

    pub fn nullValue(self: *Object, name: []const u8) !void {
        try self.raw(name, "null");
    }

    pub fn strings(self: *Object, name: []const u8, values: []const []const u8) !void {
        try self.key(name);
        try self.buffer.append(self.allocator, '[');
        for (values, 0..) |value, index| {
            if (index != 0) try self.buffer.append(self.allocator, ',');
            try writeString(self.buffer.writer(self.allocator), value);
        }
        try self.buffer.append(self.allocator, ']');
    }

    pub fn integers(self: *Object, name: []const u8, values: []const []const u8) !void {
        try self.key(name);
        try self.buffer.append(self.allocator, '[');
        for (values, 0..) |value, index| {
            if (index != 0) try self.buffer.append(self.allocator, ',');
            _ = try std.fmt.parseInt(i64, value, 10);
            try self.buffer.appendSlice(self.allocator, value);
        }
        try self.buffer.append(self.allocator, ']');
    }

    pub fn integerValues(self: *Object, name: []const u8, values: []const i64) !void {
        try self.key(name);
        try self.buffer.append(self.allocator, '[');
        for (values, 0..) |value, index| {
            if (index != 0) try self.buffer.append(self.allocator, ',');
            try self.buffer.writer(self.allocator).print("{d}", .{value});
        }
        try self.buffer.append(self.allocator, ']');
    }

    pub fn identifiers(self: *Object, name: []const u8, values: []const []const u8) !void {
        try self.key(name);
        try self.buffer.append(self.allocator, '[');
        for (values, 0..) |value, index| {
            if (index != 0) try self.buffer.append(self.allocator, ',');
            if (allDigits(value)) try self.buffer.appendSlice(self.allocator, value) else try writeString(self.buffer.writer(self.allocator), value);
        }
        try self.buffer.append(self.allocator, ']');
    }

    pub fn finish(self: *Object) ![]const u8 {
        if (!self.finished) {
            try self.buffer.append(self.allocator, '}');
            self.finished = true;
        }
        return self.buffer.items;
    }
};

fn allDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub fn appendRawField(w: anytype, key: []const u8, raw_value: []const u8, first: *bool) !void {
    if (!first.*) try w.writeByte(',');
    first.* = false;
    try w.writeByte('"');
    try w.writeAll(key);
    try w.writeAll("\":");
    try w.writeAll(raw_value);
}

pub fn isJson(value: []const u8) bool {
    if (value.len == 0) return false;
    return value[0] == '{' or value[0] == '[' or std.mem.eql(u8, value, "null") or
        std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false");
}

pub fn mergeRawField(allocator: std.mem.Allocator, object_json: []const u8, name: []const u8, value_json: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, object_json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '{' or trimmed[trimmed.len - 1] != '}') return error.InvalidJsonObject;
    var result: std.ArrayListUnmanaged(u8) = .{};
    try result.appendSlice(allocator, trimmed[0 .. trimmed.len - 1]);
    if (trimmed.len > 2) try result.append(allocator, ',');
    try writeString(result.writer(allocator), name);
    try result.append(allocator, ':');
    try result.appendSlice(allocator, value_json);
    try result.append(allocator, '}');
    return result.toOwnedSlice(allocator);
}

test "object escapes fields" {
    var object = try Object.init(std.testing.allocator);
    defer object.deinit();
    try object.string("value", "a\"b\n");
    try object.integer("count", 2);
    try std.testing.expectEqualStrings("{\"value\":\"a\\\"b\\n\",\"count\":2}", try object.finish());
}
