const std = @import("std");
const Context = @import("../command_context.zig").Context;
const query = @import("../query.zig");
const output = @import("../output.zig");
const json = @import("../json_util.zig");

const Capability = struct {
    const Self = @This();

    name: []const u8,
    description: []const u8 = "",
    commands: []const Self = &.{},
};

pub fn capabilities(context_value: *const Context) !void {
    const catalog = @embedFile("../capabilities.json");
    if (context_value.args.has("json")) return output.print(catalog);
    try output.print(try capabilitiesMarkdown(context_value.allocator, catalog));
}

fn capabilitiesMarkdown(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(Capability, allocator, source, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    const writer = result.writer(allocator);
    try writer.print("# Hypertask CLI capabilities\n\n{s}\n\n## Commands\n\n", .{parsed.value.description});

    var path: std.ArrayListUnmanaged(u8) = .{};
    defer path.deinit(allocator);
    try appendCommands(&result, &path, allocator, parsed.value.commands);
    try result.appendSlice(allocator, "\nRun `hypertask capabilities --json` for arguments, options, and aliases.\n");
    return result.toOwnedSlice(allocator);
}

fn appendCommands(result: *std.ArrayListUnmanaged(u8), path: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, commands: []const Capability) !void {
    for (commands) |command| {
        const previous_len = path.items.len;
        if (previous_len != 0) try path.append(allocator, ' ');
        try path.appendSlice(allocator, command.name);

        if (command.commands.len == 0) {
            try result.writer(allocator).print("- `{s}`: {s}\n", .{ path.items, command.description });
        } else {
            try appendCommands(result, path, allocator, command.commands);
        }
        path.shrinkRetainingCapacity(previous_len);
    }
}

test "capabilities markdown lists leaf command paths" {
    const source =
        \\{"name":"hypertask","description":"Manage tasks","commands":[{"name":"login","description":"Sign in"},{"name":"task","description":"Task commands","commands":[{"name":"get","description":"Get one task"}]}]}
    ;
    const rendered = try capabilitiesMarkdown(std.testing.allocator, source);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        \\# Hypertask CLI capabilities
        \\
        \\Manage tasks
        \\
        \\## Commands
        \\
        \\- `login`: Sign in
        \\- `task get`: Get one task
        \\
        \\Run `hypertask capabilities --json` for arguments, options, and aliases.
        \\
    , rendered);
}

pub fn update(context_value: *const Context) !void {
    try context_value.print("{\"current\":\"0.2.0-zig\",\"latest\":null,\"available\":false,\"message\":\"Automatic npm updates are not available for hypertask\"}");
}

pub fn context(context_value: *const Context) !void {
    const responses = try contextResponses(context_value);
    var user_context = responses[0];
    defer user_context.deinit();
    var projects = responses[1];
    defer projects.deinit();
    const project_document = try std.json.parseFromSlice(std.json.Value, context_value.allocator, projects.body, .{});
    defer project_document.deinit();
    const project_rows = project_document.value.object.get("projects") orelse return error.InvalidResponse;
    const project_json = try std.json.Stringify.valueAlloc(context_value.allocator, project_rows, .{});
    try context_value.print(try json.mergeRawField(context_value.allocator, user_context.body, "projects", project_json));
}

pub fn teams(context_value: *const Context) !void {
    const responses = try contextResponses(context_value);
    var user_context = responses[0];
    defer user_context.deinit();
    var projects = responses[1];
    defer projects.deinit();
    const document = try std.json.parseFromSlice(std.json.Value, context_value.allocator, user_context.body, .{});
    defer document.deinit();
    const teams_value = document.value.object.get("teams") orelse return error.InvalidResponse;
    try context_value.print(try std.json.Stringify.valueAlloc(context_value.allocator, teams_value, .{}));
}

pub fn presence(context_value: *const Context) !void {
    const team_id = try context_value.args.requirePositional(1, "team-id");
    var path = try query.Builder.init(context_value.allocator, "/mcp/agents/presence");
    defer path.deinit();
    try path.add("team_id", team_id);
    try context_value.call(.GET, path.path(), null);
}

pub fn raw(context_value: *const Context) !void {
    const method_text = try context_value.args.requirePositional(1, "METHOD");
    const path = try context_value.args.requirePositional(2, "path");
    const body = context_value.args.positionalAt(3);
    const method: std.http.Method = if (std.ascii.eqlIgnoreCase(method_text, "GET")) .GET else if (std.ascii.eqlIgnoreCase(method_text, "POST")) .POST else if (std.ascii.eqlIgnoreCase(method_text, "PUT")) .PUT else if (std.ascii.eqlIgnoreCase(method_text, "PATCH")) .PATCH else if (std.ascii.eqlIgnoreCase(method_text, "DELETE")) .DELETE else return error.InvalidMethod;
    try context_value.call(method, path, body);
}

fn contextResponses(context_value: *const Context) ![2]@import("../http.zig").Response {
    var user_context = try context_value.fetch(.GET, "/mcp/user/context", null);
    errdefer user_context.deinit();
    const user_code = @intFromEnum(user_context.status);
    if (user_code < 200 or user_code >= 300) {
        try output.finish(&user_context);
        return error.CommandFailed;
    }
    var path = try query.Builder.init(context_value.allocator, "/mcp/projects");
    defer path.deinit();
    try path.add("status", "Normal");
    try path.add("limit", "100");
    var projects = try context_value.fetch(.GET, path.path(), null);
    errdefer projects.deinit();
    const projects_code = @intFromEnum(projects.status);
    if (projects_code < 200 or projects_code >= 300) {
        try output.finish(&projects);
        return error.CommandFailed;
    }
    return .{ user_context, projects };
}
