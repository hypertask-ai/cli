const std = @import("std");
const common = @import("command_context.zig");
const Context = common.Context;
const json = @import("json_util.zig");
const resolve = @import("resolve.zig");

// The MCP API caps decoded inline data at 3 MiB, below the per-file URL limit.
const max_file_size = 3 * 1024 * 1024;

pub fn validateInputs(context: *const Context, inputs: []const []const u8) !void {
    for (inputs) |input| {
        if (!isUrl(input)) {
            const data = try readFile(context, input);
            context.allocator.free(data);
        }
    }
}

fn readFile(context: *const Context, input: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(context.allocator, input, max_file_size) catch |err| {
        std.debug.print("cannot attach '{s}': {s}\n", .{ input, @errorName(err) });
        if (err == error.FileTooBig) std.debug.print("Local attachments must be at most 3 MiB; use --attach with an https URL for larger files.\n", .{});
        return err;
    };
}

pub fn upload(context: *const Context, ticket: []const u8, comment_id: ?i64, inputs: []const []const u8) ![]u8 {
    var linked: std.ArrayListUnmanaged(u8) = .{};
    defer linked.deinit(context.allocator);
    try linked.append(context.allocator, '[');
    for (inputs, 0..) |input, index| {
        const attachment = uploadOne(context, ticket, comment_id, input) catch |err| {
            std.debug.print("Attachment '{s}' failed: {s}. The comment/task and any earlier attachments may already exist.\n", .{ input, @errorName(err) });
            return err;
        };
        defer context.allocator.free(attachment);
        if (index != 0) try linked.append(context.allocator, ',');
        try linked.appendSlice(context.allocator, attachment);
    }
    try linked.append(context.allocator, ']');
    var result = try json.Object.init(context.allocator);
    defer result.deinit();
    try result.boolean("success", true);
    try result.string("attachment_status", "complete");
    try result.raw("attachments", linked.items);
    return context.allocator.dupe(u8, try result.finish());
}

fn uploadOne(context: *const Context, ticket: []const u8, comment_id: ?i64, input: []const u8) ![]u8 {
    var part = try json.Object.init(context.allocator);
    defer part.deinit();
    if (isUrl(input)) {
        try part.string("filename", urlFilename(input));
        try part.string("content_type", mimeType(input));
        try part.string("url", input);
    } else {
        const data = try readFile(context, input);
        defer context.allocator.free(data);
        const encoded = try context.allocator.alloc(u8, std.base64.standard.Encoder.calcSize(data.len));
        defer context.allocator.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, data);
        try part.string("filename", std.fs.path.basename(input));
        try part.string("content_type", sniffMime(data) orelse mimeType(input));
        try part.string("data", encoded);
    }
    const files = try std.fmt.allocPrint(context.allocator, "[{s}]", .{try part.finish()});
    defer context.allocator.free(files);
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try resolve.addTaskIdentifierBodyForProject(&body, context.allocator, ticket, context.args.get("project"));
    if (comment_id) |id| try body.integer("comment_id", id);
    try body.raw("files", files);
    var response = try context.fetch(.POST, "/mcp/tasks/attachments", try body.finish());
    defer response.deinit();

    if (!response.isSuccess()) {
        try context.finish(&response);
        return error.CommandFailed;
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const success = parsed.value.object.get("success") orelse return error.InvalidResponse;
    if (success != .bool or !success.bool) return error.InvalidResponse;
    const attached = parsed.value.object.get("attachments") orelse return error.InvalidResponse;
    if (attached != .array or attached.array.items.len != 1) return error.InvalidResponse;
    const attachment = attached.array.items[0];
    if (attachment != .object) return error.InvalidResponse;
    const id = attachment.object.get("id") orelse return error.InvalidResponse;
    if (id != .integer or id.integer <= 0) return error.InvalidResponse;
    return std.json.Stringify.valueAlloc(context.allocator, attachment, .{});
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

test "explicit internal comment attachment identifiers use task_id" {
    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try resolve.addTaskIdentifierBody(&body, std.testing.allocator, "id:34874");
    try body.integer("comment_id", 7);
    try std.testing.expectEqualStrings("{\"task_id\":34874,\"comment_id\":7}", try body.finish());
}

test "comment attachment ticket identifiers keep ticket_number" {
    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try resolve.addTaskIdentifierBody(&body, std.testing.allocator, "AEXP-1");
    try body.integer("comment_id", 7);
    try std.testing.expectEqualStrings("{\"ticket_number\":\"AEXP-1\",\"comment_id\":7}", try body.finish());
}

test "attachment uploads reject successful responses with no linked attachment" {
    const args = @import("args.zig");
    const config = @import("config.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try args.parse(allocator, &.{});
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
    var recorder = common.RequestRecorder.init(allocator);
    defer recorder.deinit();
    recorder.responses = &.{"{\"success\":true,\"attachments\":[]}"};
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = Context{ .client = &client, .allocator = allocator, .args = &parsed, .cfg = &cfg, .json = true, .request_recorder = &recorder };
    try std.testing.expectError(error.InvalidResponse, upload(&context, "HTPR-6834", 7, &.{"https://example.test/a.png"}));
}

test "attachment uploads send every repeated input separately and retain the comment id" {
    const args = @import("args.zig");
    const config = @import("config.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parsed = try args.parse(allocator, &.{ "comment", "add", "HTPR-6834", "--attach", "https://example.test/a.png", "--attach", "https://example.test/b.png", "--attach", "https://example.test/c.webm" });
    defer parsed.deinit();
    var cfg = config.Config{ .allocator = allocator, .token = "test-token" };
    var recorder = common.RequestRecorder.init(allocator);
    defer recorder.deinit();
    recorder.responses = &.{
        "{\"success\":true,\"attachments\":[{\"id\":1}]}",
        "{\"success\":true,\"attachments\":[{\"id\":2}]}",
        "{\"success\":true,\"attachments\":[{\"id\":3}]}",
    };
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const context = Context{ .client = &client, .allocator = allocator, .args = &parsed, .cfg = &cfg, .json = true, .request_recorder = &recorder };
    const result = try upload(&context, "HTPR-6834", 7, try common.optionList(&context, "attach"));
    try std.testing.expectEqual(@as(usize, 3), recorder.responses_index);
    try std.testing.expectEqualStrings("{\"success\":true,\"attachment_status\":\"complete\",\"attachments\":[{\"id\":1},{\"id\":2},{\"id\":3}]}", result);
    try std.testing.expectEqualStrings("{\"ticket_number\":\"HTPR-6834\",\"comment_id\":7,\"files\":[{\"filename\":\"c.webm\",\"content_type\":\"application/octet-stream\",\"url\":\"https://example.test/c.webm\"}]}", recorder.body.?);
}
