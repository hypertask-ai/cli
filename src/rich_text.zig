const std = @import("std");

pub const Result = struct {
    text: []const u8,
    wrapped: bool,
};

const block_tags = [_][]const u8{ "p", "ul", "ol", "h2", "blockquote", "pre" };
const whitespace = " \t\r\n";

pub fn normalize(allocator: std.mem.Allocator, input: []const u8) !Result {
    const trimmed = std.mem.trim(u8, input, whitespace);
    if (startsWithBlockTag(trimmed)) return .{ .text = trimmed, .wrapped = false };

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    var paragraph_start: usize = 0;
    var index: usize = 0;
    while (index < trimmed.len) : (index += 1) {
        if (blankLineEnd(trimmed, index)) |separator_end| {
            try appendParagraph(&output, allocator, trimmed[paragraph_start..index]);
            paragraph_start = separator_end;
            index = separator_end - 1;
        }
    }
    try appendParagraph(&output, allocator, trimmed[paragraph_start..]);
    if (output.items.len == 0) try output.appendSlice(allocator, "<p></p>");

    return .{ .text = try output.toOwnedSlice(allocator), .wrapped = true };
}

fn startsWithBlockTag(text: []const u8) bool {
    if (text.len < 3 or text[0] != '<') return false;
    for (block_tags) |tag| {
        if (text.len <= tag.len + 1) continue;
        if (!std.ascii.eqlIgnoreCase(text[1 .. tag.len + 1], tag)) continue;
        const next = text[tag.len + 1];
        if (next == '>' or std.ascii.isWhitespace(next)) return true;
    }
    return false;
}

fn blankLineEnd(text: []const u8, index: usize) ?usize {
    if (text[index] != '\n') return null;
    var cursor = index + 1;
    while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t' or text[cursor] == '\r')) : (cursor += 1) {}
    if (cursor >= text.len or text[cursor] != '\n') return null;
    return cursor + 1;
}

fn appendParagraph(output: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    const paragraph = std.mem.trim(u8, input, whitespace);
    if (paragraph.len == 0) return;
    try output.appendSlice(allocator, "<p>");
    try output.appendSlice(allocator, paragraph);
    try output.appendSlice(allocator, "</p>");
}

test "normalize wraps bare text and splits blank lines" {
    const result = try normalize(std.testing.allocator, " First paragraph\r\n \r\nSecond paragraph ");
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.wrapped);
    try std.testing.expectEqualStrings("<p>First paragraph</p><p>Second paragraph</p>", result.text);
}

test "normalize recognizes supported leading block tags" {
    inline for (block_tags) |tag| {
        const input = try std.fmt.allocPrint(std.testing.allocator, "  <{s} class=\"x\">Already HTML</{s}>  ", .{ tag, tag });
        defer std.testing.allocator.free(input);
        const result = try normalize(std.testing.allocator, input);
        try std.testing.expect(!result.wrapped);
        try std.testing.expect(result.text.len < input.len);
    }
}

test "normalize wraps inline HTML" {
    const result = try normalize(std.testing.allocator, "<strong>Important</strong>");
    defer std.testing.allocator.free(result.text);
    try std.testing.expect(result.wrapped);
    try std.testing.expectEqualStrings("<p><strong>Important</strong></p>", result.text);
}
