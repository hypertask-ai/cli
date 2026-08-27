const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");
const resolve = @import("../resolve.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "create")) return create(context);
    if (std.mem.eql(u8, subcommand, "get")) return get(context);
    if (std.mem.eql(u8, subcommand, "append")) return update(context, "append");
    if (std.mem.eql(u8, subcommand, "update")) return update(context, context.args.get("mode") orelse "replace");
    if (std.mem.eql(u8, subcommand, "list")) return list(context);
    if (std.mem.eql(u8, subcommand, "archive") or std.mem.eql(u8, subcommand, "delete")) return bodyId(context, "/mcp/pages/archive", false);
    if (std.mem.eql(u8, subcommand, "history")) return history(context);
    if (std.mem.eql(u8, subcommand, "restore")) return bodyId(context, "/mcp/pages/restore", true);
    if (std.mem.eql(u8, subcommand, "search")) return search(context);
    return error.UnknownCommand;
}

fn content(context: *const Context) ![]const u8 {
    if (context.args.get("markdown-file")) |path| return common.readFile(context.allocator, path, 10 * 1024 * 1024);
    return context.args.require("content");
}

fn contentType(context: *const Context) []const u8 {
    if (context.args.has("canvas")) return "html_canvas";
    if (context.args.has("html")) return "html";
    return "markdown";
}

fn addPageId(body: *json.Object, id: []const u8) !void {
    if (resolve.isNumeric(id)) try body.integer("id", try common.positiveInt(id, "id")) else try body.string("id", id);
}

fn create(context: *const Context) !void {
    const task = try context.args.require("task");
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    if (resolve.isNumeric(task)) try body.integer("task_id", try common.positiveInt(task, "task")) else try body.string("ticket_number", task);
    if (context.args.get("title")) |value| try body.string("title", value);
    try body.string("content", try content(context));
    try body.string("content_type", contentType(context));
    if (context.args.get("parent")) |value| try body.integer("parent_page_id", try common.positiveInt(value, "parent"));
    try context.call(.POST, "/mcp/pages/create", try body.finish());
}

fn get(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/pages/get");
    defer path.deinit();
    try path.add("id", try context.args.requirePositional(2, "id"));
    try path.add("format", context.args.get("format") orelse "markdown");
    try context.call(.GET, path.path(), null);
}

fn update(context: *const Context, mode: []const u8) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try addPageId(&body, try context.args.requirePositional(2, "id"));
    if (context.args.get("title")) |value| try body.string("title", value);
    if (context.args.get("content") != null or context.args.get("markdown-file") != null) {
        try body.string("content", try content(context));
        try body.string("content_type", contentType(context));
        try body.string("mode", mode);
    }
    if (context.args.get("if-version")) |value| try body.integer("if_version", try common.positiveInt(value, "if-version"));
    if (context.args.get("note")) |value| try body.string("note", value);
    try context.call(.POST, "/mcp/pages/update", try body.finish());
}

fn list(context: *const Context) !void {
    if ((context.args.get("task") == null) == (context.args.get("project") == null)) return error.InvalidOptions;
    var path = try query.Builder.init(context.allocator, "/mcp/pages/list");
    defer path.deinit();
    if (context.args.get("task")) |value| {
        if (resolve.isNumeric(value)) try path.add("task_id", value) else try path.add("ticket_number", value);
    }
    if (context.args.get("project")) |value| try path.add("project_id", value);
    try context.call(.GET, path.path(), null);
}

fn bodyId(context: *const Context, path: []const u8, restore: bool) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try addPageId(&body, try context.args.requirePositional(2, "id"));
    if (restore) try body.integer("version_id", try common.positiveInt(try context.args.require("version"), "version"));
    try context.call(.POST, path, try body.finish());
}

fn history(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/pages/versions");
    defer path.deinit();
    try path.add("id", try context.args.requirePositional(2, "id"));
    try context.call(.GET, path.path(), null);
}

fn search(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/pages/search");
    defer path.deinit();
    try path.add("q", try context.args.requirePositional(2, "query"));
    try context.call(.GET, path.path(), null);
}
