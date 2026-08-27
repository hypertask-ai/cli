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
        try path.add("ticket_number", try context.args.requirePositional(2, "ticket"));
        return context.call(.GET, path.path(), null);
    }
    if (std.mem.eql(u8, subcommand, "add")) {
        if (context.args.get("improve-command") != null and !context.args.has("improve")) return error.InvalidOptions;
        var text = if (context.args.get("file")) |path| try common.readFile(context.allocator, path, 1024 * 1024) else context.args.get("text") orelse context.args.get("body") orelse return error.MissingOption;
        const ticket = try context.args.requirePositional(2, "ticket");
        if (context.args.has("improve")) text = try improve(context, ticket, text);
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        try body.string("ticket_number", ticket);
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
        try output.print(try json.mergeRawField(context.allocator, response.body, "attachments_uploaded", uploaded));
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
