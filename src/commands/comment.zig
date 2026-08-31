const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");
const attachments = @import("../attachments.zig");
const output = @import("../output.zig");
const resolve = @import("../resolve.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) {
        var path = try query.Builder.init(context.allocator, "/mcp/comments");
        defer path.deinit();
        try addIdentifierQuery(&path, try context.args.requirePositional(2, "ticket"));
        var response = try context.fetch(.GET, path.path(), null);
        defer response.deinit();
        const code = @intFromEnum(response.status);
        if (code < 200 or code >= 300) return output.finish(&response);
        const body = try addHasMore(context.allocator, response.body);
        defer context.allocator.free(body);
        return context.print(body);
    }
    if (std.mem.eql(u8, subcommand, "add")) {
        if (context.args.get("improve-command") != null and !context.args.has("improve")) return error.InvalidOptions;
        var text = if (context.args.get("file")) |path| try common.readFile(context.allocator, path, 1024 * 1024) else context.args.get("text") orelse context.args.get("body") orelse return error.MissingOption;
        const ticket = try context.args.requirePositional(2, "ticket");
        if (context.args.has("improve")) text = try improve(context, ticket, text);
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try addIdentifierBody(&body, ticket);
        try body.string("text", text);
        if (context.args.has("markdown")) try body.string("content_type", "markdown");
        const attach_inputs = try common.optionList(context, "attach");
        if (attach_inputs.len == 0) return context.call(.POST, "/mcp/comments", try body.finish());
        var response = try context.fetch(.POST, "/mcp/comments", try body.finish());
        defer response.deinit();
        const code = @intFromEnum(response.status);
        if (code < 200 or code >= 300) return output.finish(&response);
        const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
        defer parsed.deinit();
        const comment_value = parsed.value.object.get("comment") orelse return error.InvalidResponse;
        const id_value = comment_value.object.get("id") orelse return error.InvalidResponse;
        const comment_id = switch (id_value) {
            .integer => |value| value,
            else => return error.InvalidResponse,
        };
        const uploaded = try attachments.upload(context, ticket, comment_id, attach_inputs);
        try context.print(try json.mergeRawField(context.allocator, response.body, "attachments_uploaded", uploaded));
        return;
    }
    const id = try context.args.requirePositional(2, "id");
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/comments/{s}", .{id});
    if (std.mem.eql(u8, subcommand, "update")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("text", try context.args.require("text"));
        return context.call(.PATCH, path, try body.finish());
    }
    if (std.mem.eql(u8, subcommand, "delete")) return context.call(.DELETE, path, null);
    return error.UnknownCommand;
}

fn addIdentifierQuery(path: *query.Builder, identifier: []const u8) !void {
    if (resolve.isNumeric(identifier)) {
        try path.add("task_id", identifier);
    } else {
        try path.add("ticket_number", identifier);
    }
}

fn addIdentifierBody(body: *json.Object, identifier: []const u8) !void {
    if (resolve.isNumeric(identifier)) {
        try body.integer("task_id", try common.positiveInt(identifier, "task-id"));
    } else {
        try body.string("ticket_number", identifier);
    }
}

fn improve(context: *const Context, ticket: []const u8, text: []const u8) ![]const u8 {
    const task = try resolve.task(context, ticket);
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("project_id", task.project_id);
    try body.string("text", text);
    try body.string("command", improveCommand(context.args.get("improve-command") orelse "improve-readability"));
    var response = try context.fetch(.POST, "/mcp/ai/improve", try body.finish());
    defer response.deinit();
    const code = @intFromEnum(response.status);
    if (code < 200 or code >= 300) return error.CommandFailed;
    const parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
    defer parsed.deinit();
    const html = parsed.value.object.get("html") orelse return error.InvalidResponse;
    if (html != .string) return error.InvalidResponse;
    return context.allocator.dupe(u8, html.string);
}

fn improveCommand(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "fix-spelling")) return "FixSpellingAndGrammar";
    if (std.mem.eql(u8, value, "summarize")) return "Summarize";
    if (std.mem.eql(u8, value, "make-shorter")) return "MakeShorter";
    return "ImproveReadability";
}

fn addHasMore(allocator: std.mem.Allocator, response_body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    if (parsed.value.object.get("has_more") != null) return allocator.dupe(u8, response_body);

    const comments = parsed.value.object.get("comments");
    const total = parsed.value.object.get("total");
    const offset = parsed.value.object.get("offset");
    const returned: i64 = if (comments != null and comments.? == .array)
        @intCast(comments.?.array.items.len)
    else
        0;
    const total_count: i64 = if (total != null and total.? == .integer) total.?.integer else returned;
    const start: i64 = if (offset != null and offset.? == .integer) offset.?.integer else 0;
    return json.mergeRawField(
        allocator,
        response_body,
        "has_more",
        if (start >= 0 and start + returned < total_count) "true" else "false",
    );
}

test "numeric comment identifiers use task_id" {
    var path = try query.Builder.init(std.testing.allocator, "/mcp/comments");
    defer path.deinit();
    try addIdentifierQuery(&path, "34874");
    try std.testing.expectEqualStrings("/mcp/comments?task_id=34874", path.path());

    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try addIdentifierBody(&body, "34874");
    try body.string("text", "x");
    try std.testing.expectEqualStrings("{\"task_id\":34874,\"text\":\"x\"}", try body.finish());
}

test "comment ticket identifiers keep ticket_number" {
    var path = try query.Builder.init(std.testing.allocator, "/mcp/comments");
    defer path.deinit();
    try addIdentifierQuery(&path, "AEXP-1");
    try std.testing.expectEqualStrings("/mcp/comments?ticket_number=AEXP-1", path.path());

    var body = try json.Object.init(std.testing.allocator);
    defer body.deinit();
    try addIdentifierBody(&body, "AEXP-1");
    try body.string("text", "x");
    try std.testing.expectEqualStrings("{\"ticket_number\":\"AEXP-1\",\"text\":\"x\"}", try body.finish());
}
