const std = @import("std");
const common = @import("command_context.zig");
const Context = common.Context;
const json = @import("json_util.zig");
const output = @import("output.zig");
const resolve = @import("resolve.zig");

const max_file_size = 15 * 1024 * 1024;

pub fn upload(context: *const Context, ticket: []const u8, comment_id: ?i64, inputs: []const []const u8) ![]u8 {
    var files: std.ArrayListUnmanaged(u8) = .{};
    try files.append(context.allocator, '[');
    for (inputs, 0..) |input, index| {
        if (index != 0) try files.append(context.allocator, ',');
        var part = try json.Object.init(context.allocator);
        defer part.deinit();
        if (isUrl(input)) {
            try part.string("filename", urlFilename(input));
            try part.string("content_type", mimeType(input));
            try part.string("url", input);
        } else {
            const data = try std.fs.cwd().readFileAlloc(context.allocator, input, max_file_size);
            const encoded_size = std.base64.standard.Encoder.calcSize(data.len);
            const encoded = try context.allocator.alloc(u8, encoded_size);
            _ = std.base64.standard.Encoder.encode(encoded, data);
            try part.string("filename", std.fs.path.basename(input));
            try part.string("content_type", sniffMime(data) orelse mimeType(input));
            try part.string("data", encoded);
        }
        try files.appendSlice(context.allocator, try part.finish());
    }
    try files.append(context.allocator, ']');

    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try addIdentifierBody(&body, ticket);
    if (comment_id) |id| try body.integer("comment_id", id);
    try body.raw("files", files.items);
    var response = try context.fetch(.POST, "/mcp/tasks/attachments", try body.finish());
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) {
        output.finish(&response) catch {};
        return error.CommandFailed;
    }
    return context.allocator.dupe(u8, response.body);
}

fn addIdentifierBody(body: *json.Object, identifier: []const u8) !void {
    if (resolve.isNumeric(identifier)) {
        try body.integer("task_id", try common.positiveInt(identifier, "task-id"));
    } else {
        try body.string("ticket_number", identifier);
    }
}

fn isUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "http://") or std.mem.startsWith(u8, value, "https://");
}

fn urlFilename(value: []const u8) []const u8 {
    const without_query = if (std.mem.indexOfScalar(u8, value, '?')) |index| value[0..index] else value;
    const name = std.fs.path.basename(without_query);
    return if (name.len == 0) "attachment" else name;
}

fn mimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".gif")) return "image/gif";
    if (std.ascii.eqlIgnoreCase(extension, ".pdf")) return "application/pdf";
    if (std.ascii.eqlIgnoreCase(extension, ".md") or std.ascii.eqlIgnoreCase(extension, ".markdown")) return "text/markdown";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(extension, ".csv")) return "text/csv";
    if (std.ascii.eqlIgnoreCase(extension, ".html") or std.ascii.eqlIgnoreCase(extension, ".htm")) return "text/html";
    return "application/octet-stream";
}

fn sniffMime(data: []const u8) ?[]const u8 {
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "\x89PNG")) return "image/png";
    if (data.len >= 3 and std.mem.eql(u8, data[0..3], "\xff\xd8\xff")) return "image/jpeg";
    if (data.len >= 6 and (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a"))) return "image/gif";
    if (data.len >= 4 and std.mem.eql(u8, data[0..4], "%PDF")) return "application/pdf";
    return null;
}

test "attachment MIME detection uses extensions and file signatures" {
    try std.testing.expectEqualStrings("image/png", mimeType("IMAGE.PNG"));
    try std.testing.expectEqualStrings("image/jpeg", mimeType("photo.jpeg"));
    try std.testing.expectEqualStrings("text/markdown", mimeType("notes.md"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeType("archive.bin"));

    try std.testing.expectEqualStrings("image/png", sniffMime("\x89PNG\r\n").?);
    try std.testing.expectEqualStrings("image/jpeg", sniffMime("\xff\xd8\xffrest").?);
    try std.testing.expectEqualStrings("image/gif", sniffMime("GIF89a...").?);
    try std.testing.expectEqualStrings("application/pdf", sniffMime("%PDF-1.7").?);
    try std.testing.expect(sniffMime("plain text") == null);
}

test "numeric comment attachment identifiers use task_id" {
    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try addIdentifierBody(&body, "34874");
    try body.integer("comment_id", 7);
    try std.testing.expectEqualStrings("{\"task_id\":34874,\"comment_id\":7}", try body.finish());
}

test "comment attachment ticket identifiers keep ticket_number" {
    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try addIdentifierBody(&body, "AEXP-1");
    try body.integer("comment_id", 7);
    try std.testing.expectEqualStrings("{\"ticket_number\":\"AEXP-1\",\"comment_id\":7}", try body.finish());
}
