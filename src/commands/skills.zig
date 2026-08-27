const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) {
        var path = try query.Builder.init(context.allocator, "/mcp/skills");
        defer path.deinit();
        if (context.args.get("project")) |value| try path.add("project_id", value);
        return context.call(.GET, path.path(), null);
    }
    if (std.mem.eql(u8, subcommand, "get")) return context.call(.GET, try skillPath(context), null);
    if (std.mem.eql(u8, subcommand, "delete")) return context.call(.DELETE, try skillPath(context), null);
    if (std.mem.eql(u8, subcommand, "import")) return importSkills(context);
    if (std.mem.eql(u8, subcommand, "create") or std.mem.eql(u8, subcommand, "update")) {
        var body = try json.Object.init(context.allocator);
        defer body.deinit();
        const string_fields = [_][2][]const u8{
            .{ "name", "name" }, .{ "slug", "slug" }, .{ "body", "body" }, .{ "description", "description" }, .{ "argument-hint", "argument_hint" }, .{ "scope", "scope" },
        };
        for (string_fields) |field| if (context.args.get(field[0])) |value| try body.string(field[1], value);
        if (context.args.get("project")) |value| try body.integer("project_id", try common.positiveInt(value, "project"));
        if (context.args.get("markdown")) |path| try body.string("markdown", try common.readFile(context.allocator, path, 2 * 1024 * 1024));
        if (context.args.has("disabled")) try body.boolean("enabled", false);
        if (context.args.has("enabled")) try body.boolean("enabled", true);
        return context.call(if (std.mem.eql(u8, subcommand, "create")) .POST else .PATCH, if (std.mem.eql(u8, subcommand, "create")) "/mcp/skills" else try skillPath(context), try body.finish());
    }
    return error.UnknownCommand;
}

fn skillPath(context: *const Context) ![]const u8 {
    const id = try context.args.requirePositional(2, "id");
    _ = try common.positiveInt(id, "id");
    return std.fmt.allocPrint(context.allocator, "/mcp/skills/{s}", .{id});
}

fn importSkills(context: *const Context) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("url", try context.args.requirePositional(2, "github-url"));
    try body.string("scope", context.args.get("scope") orelse "user");
    if (context.args.get("project")) |value| try body.integer("project_id", try common.positiveInt(value, "project"));
    if (context.args.has("dry-run")) try body.boolean("dry_run", true);
    const slugs = try common.optionList(context, "slugs");
    if (slugs.len != 0) try body.strings("slugs", slugs);
    try context.call(.POST, "/mcp/skills/import", try body.finish());
}
