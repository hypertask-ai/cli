const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    const project = try common.positiveInt(try context.args.require("project"), "project");
    if (std.mem.eql(u8, subcommand, "list") or std.mem.eql(u8, subcommand, "get")) {
        var path = try query.Builder.init(context.allocator, if (std.mem.eql(u8, subcommand, "list")) "/mcp/reports/list" else "/mcp/reports/get");
        defer path.deinit();
        try path.addInt("project_id", project);
        if (std.mem.eql(u8, subcommand, "get")) try path.add("slug", try context.args.requirePositional(2, "slug"));
        return context.call(.GET, path.path(), null);
    }
    const slug = try context.args.requirePositional(2, "slug");
    if (std.mem.eql(u8, subcommand, "delete") and !context.args.has("confirm")) return error.ConfirmationRequired;
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("project_id", project);
    try body.string("slug", slug);
    if (context.args.get("title")) |value| try body.string("title", value);
    if (context.args.has("clear-description")) try body.nullValue("description") else if (context.args.get("description")) |value| try body.string("description", value);
    if (context.args.get("html-file")) |path| try body.string("body_html", try common.readFile(context.allocator, path, 500_000)) else if (context.args.get("body")) |value| try body.string("body_html", value);
    const path = if (std.mem.eql(u8, subcommand, "create")) "/mcp/reports/create" else if (std.mem.eql(u8, subcommand, "update")) "/mcp/reports/update" else if (std.mem.eql(u8, subcommand, "delete")) "/mcp/reports/delete" else return error.UnknownCommand;
    try context.call(.POST, path, try body.finish());
}
