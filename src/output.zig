const std = @import("std");
const http = @import("http.zig");

pub fn print(body: []const u8) !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try stdout.writeAll("\n");
}

pub fn printResponse(allocator: std.mem.Allocator, body: []const u8, json: bool) !void {
    if (json) return print(body);
    const formatted = try formatHuman(allocator, body);
    defer allocator.free(formatted);
    try print(formatted);
}

pub fn finish(response: *http.Response) !void {
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        try print(response.body);
        return apiError(response.status);
    }
    try print(response.body);
}

fn apiError(status: std.http.Status) anyerror {
    return switch (status) {
        .bad_request, .unprocessable_entity => error.ApiInvalidInput,
        .unauthorized, .forbidden => error.ApiAuthentication,
        .not_found => error.ApiNotFound,
        else => error.ApiFailure,
    };
}

pub fn exitCode(err: anyerror) u8 {
    return switch (err) {
        error.MissingOption,
        error.MissingSubcommand,
        error.InvalidInteger,
        error.InvalidOptions,
        error.InvalidProject,
        error.UnknownCommand,
        error.ApiInvalidInput,
        => 2,
        error.TaskNotFound,
        error.ProjectNotFound,
        error.SectionNotFound,
        error.FieldNotFound,
        error.LabelNotFound,
        error.ApiNotFound,
        error.ApiFailure,
        error.CommandFailed,
        => 4,
        else => 1,
    };
}

pub fn responseBodyWasPrinted(err: anyerror) bool {
    return switch (err) {
        error.ApiInvalidInput,
        error.ApiAuthentication,
        error.ApiNotFound,
        error.ApiFailure,
        => true,
        else => false,
    };
}

pub fn finishResponse(allocator: std.mem.Allocator, response: *http.Response, json: bool) !void {
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return finish(response);
    try printResponse(allocator, response.body, json);
}

pub fn formatHuman(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        return allocator.dupe(u8, body);
    };
    defer parsed.deinit();

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    try renderValue(allocator, result.writer(allocator), parsed.value, 0);
    while (result.items.len > 0 and result.items[result.items.len - 1] == '\n') {
        _ = result.pop();
    }
    return result.toOwnedSlice(allocator);
}

fn renderValue(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value, indent: usize) anyerror!void {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try writeIndent(writer, indent);
                try writeSanitized(writer, entry.key_ptr.*);
                if (isScalar(entry.value_ptr.*)) {
                    try writer.writeAll(": ");
                    try writeCell(allocator, writer, entry.value_ptr.*);
                    try writer.writeByte('\n');
                } else {
                    try writer.writeAll(":\n");
                    try renderValue(allocator, writer, entry.value_ptr.*, indent + 2);
                }
            }
        },
        .array => |array| try renderArray(allocator, writer, array.items, indent),
        else => {
            try writeIndent(writer, indent);
            try writeCell(allocator, writer, value);
            try writer.writeByte('\n');
        },
    }
}

fn renderArray(allocator: std.mem.Allocator, writer: anytype, values: []const std.json.Value, indent: usize) anyerror!void {
    if (values.len == 0) {
        try writeIndent(writer, indent);
        try writer.writeAll("(none)\n");
        return;
    }

    if (canRenderTable(values)) return renderObjectTable(allocator, writer, values, indent);

    for (values) |value| {
        try writeIndent(writer, indent);
        try writer.writeByte('-');
        if (isScalar(value)) {
            try writer.writeByte(' ');
            try writeCell(allocator, writer, value);
            try writer.writeByte('\n');
        } else {
            try writer.writeByte('\n');
            try renderValue(allocator, writer, value, indent + 2);
        }
    }
}

fn canRenderTable(values: []const std.json.Value) bool {
    if (values.len == 0 or values[0] != .object) return false;
    const headers = values[0].object;
    for (values) |value| {
        if (value != .object or value.object.count() != headers.count()) return false;
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            const cell = value.object.get(entry.key_ptr.*) orelse return false;
            if (!isScalar(cell)) return false;
        }
    }
    return true;
}

fn renderObjectTable(allocator: std.mem.Allocator, writer: anytype, values: []const std.json.Value, indent: usize) !void {
    const headers = values[0].object;
    try writeIndent(writer, indent);
    var header_iterator = headers.iterator();
    var first = true;
    while (header_iterator.next()) |entry| {
        if (!first) try writer.writeByte('\t');
        first = false;
        try writeSanitized(writer, entry.key_ptr.*);
    }
    try writer.writeByte('\n');

    for (values) |value| {
        try writeIndent(writer, indent);
        header_iterator = headers.iterator();
        first = true;
        while (header_iterator.next()) |entry| {
            if (!first) try writer.writeByte('\t');
            first = false;
            if (value.object.get(entry.key_ptr.*)) |cell| {
                try writeCell(allocator, writer, cell);
            } else {
                try writer.writeByte('-');
            }
        }
        try writer.writeByte('\n');
    }
}

fn isScalar(value: std.json.Value) bool {
    return switch (value) {
        .object, .array => false,
        else => true,
    };
}

fn writeCell(allocator: std.mem.Allocator, writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeByte('-'),
        .bool => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.print("{d}", .{integer}),
        .float => |float| try writer.print("{d}", .{float}),
        .number_string => |number| try writer.writeAll(number),
        .string => |string| try writeSanitized(writer, string),
        .object, .array => {
            const raw = try std.json.Stringify.valueAlloc(allocator, value, .{});
            defer allocator.free(raw);
            try writeSanitized(writer, raw);
        },
    }
}

fn writeIndent(writer: anytype, count: usize) !void {
    for (0..count) |_| try writer.writeByte(' ');
}

fn writeSanitized(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
        try writer.writeByte(switch (byte) {
            '\t', '\r', '\n' => ' ',
            else => byte,
        });
    }
}

pub fn fail(message: []const u8) noreturn {
    std.fs.File.stderr().writeAll(message) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}

pub fn failFmt(allocator: std.mem.Allocator, comptime format: []const u8, values: anytype) noreturn {
    const message = std.fmt.allocPrint(allocator, format, values) catch fail("error");
    defer allocator.free(message);
    fail(message);
}

test "human output formats status fields without JSON syntax" {
    const formatted = try formatHuman(std.testing.allocator,
        \\{"authenticated":true,"hasToken":true,"apiUrl":"https://api.hypertask.ai/api"}
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        \\authenticated: true
        \\hasToken: true
        \\apiUrl: https://api.hypertask.ai/api
    , formatted);
}

test "human output formats object arrays as tabular rows" {
    const formatted = try formatHuman(std.testing.allocator,
        \\{"success":true,"tasks":[{"ticketNumber":"HTPR-1","title":"First"},{"ticketNumber":"HTPR-2","title":"Second"}]}
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        \\success: true
        \\tasks:
        \\  ticketNumber\ttitle
        \\  HTPR-1\tFirst
        \\  HTPR-2\tSecond
    , formatted);
}

test "human output expands nested list fields without raw JSON cells" {
    const formatted = try formatHuman(std.testing.allocator,
        \\{"tasks":[{"ticketNumber":"HTPR-1","labels":[{"name":"Bug"}]}]}
    );
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(
        \\tasks:
        \\  -
        \\    ticketNumber: HTPR-1
        \\    labels:
        \\      name
        \\      Bug
    , formatted);
}

test "human output preserves non-JSON responses" {
    const formatted = try formatHuman(std.testing.allocator, "plain text");
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings("plain text", formatted);
}
