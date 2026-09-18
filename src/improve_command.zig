const std = @import("std");

const translate_prefix = "translate:";
const valid_values = "improve-readability, fix-spelling, summarize, make-shorter, translate:<language>";

pub fn parse(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (std.mem.eql(u8, value, "improve-readability")) return "ImproveReadability";
    if (std.mem.eql(u8, value, "fix-spelling")) return "FixSpellingAndGrammar";
    if (std.mem.eql(u8, value, "summarize")) return "Summarize";
    if (std.mem.eql(u8, value, "make-shorter")) return "MakeShorter";

    if (value.len > translate_prefix.len and std.ascii.eqlIgnoreCase(value[0..translate_prefix.len], translate_prefix)) {
        const language = value[translate_prefix.len..];
        if (validLanguage(language)) return formatTranslation(allocator, language);
    }

    std.debug.print("invalid improve command: {s}\nvalid improve commands: {s}\n", .{ value, valid_values });
    return error.InvalidOptions;
}

fn validLanguage(language: []const u8) bool {
    if (language.len == 0 or language.len > 40 or !std.ascii.isAlphabetic(language[0])) return false;
    for (language[1..]) |byte| {
        if (!std.ascii.isAlphabetic(byte) and byte != ' ' and byte != '-') return false;
    }
    return true;
}

fn formatTranslation(allocator: std.mem.Allocator, language: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, "Translate:".len + language.len);
    @memcpy(result[0.."Translate:".len], "Translate:");
    var capitalize = true;
    for (language, 0..) |byte, index| {
        result["Translate:".len + index] = if (capitalize) std.ascii.toUpper(byte) else std.ascii.toLower(byte);
        capitalize = byte == ' ' or byte == '-';
    }
    return result;
}

test "improve commands reject typos and preserve translations" {
    try std.testing.expectEqualStrings("Summarize", try parse(std.testing.allocator, "summarize"));

    const translation = try parse(std.testing.allocator, "translate:brazilian portuguese");
    defer std.testing.allocator.free(translation);
    try std.testing.expectEqualStrings("Translate:Brazilian Portuguese", translation);

    try std.testing.expectError(error.InvalidOptions, parse(std.testing.allocator, "summarise"));
    try std.testing.expectError(error.InvalidOptions, parse(std.testing.allocator, "translate:"));
    try std.testing.expectError(error.InvalidOptions, parse(std.testing.allocator, "translate:German!"));
}
