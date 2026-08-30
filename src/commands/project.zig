const std = @import("std");
const common = @import("../command_context.zig");
const Context = common.Context;
const json = @import("../json_util.zig");
const query = @import("../query.zig");
const output = @import("../output.zig");

pub fn run(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) return list(context);
    if (std.mem.eql(u8, subcommand, "show")) return show(context);
    if (std.mem.eql(u8, subcommand, "manifest")) return simpleProjectGet(context, "manifest");
    if (std.mem.eql(u8, subcommand, "playbook")) return playbook(context);
    if (std.mem.eql(u8, subcommand, "instructions")) return instructions(context);
    if (std.mem.eql(u8, subcommand, "members")) return projectResource(context, "members", .GET, null);
    if (std.mem.eql(u8, subcommand, "sections")) return projectResource(context, "sections", .GET, null);
    if (std.mem.eql(u8, subcommand, "invite")) return invite(context);
    if (std.mem.eql(u8, subcommand, "labels")) return labels(context, try context.args.requirePositional(2, "project-id"));
    if (std.mem.eql(u8, subcommand, "label")) {
        if (!std.mem.eql(u8, try context.args.requirePositional(2, "subcommand"), "create")) return error.UnknownCommand;
        return createLabel(context);
    }
    if (std.mem.eql(u8, subcommand, "archive")) return archive(context);
    if (std.mem.eql(u8, subcommand, "create-board") or std.mem.eql(u8, subcommand, "create")) return createBoard(context);
    return error.UnknownCommand;
}

pub fn labelsCommand(context: *const Context, subcommand: []const u8) !void {
    if (std.mem.eql(u8, subcommand, "list")) return labels(context, try context.args.require("project"));
    if (std.mem.eql(u8, subcommand, "create")) return createLabel(context);
    return error.UnknownCommand;
}

fn list(context: *const Context) !void {
    var path = try query.Builder.init(context.allocator, "/mcp/projects");
    defer path.deinit();
    try path.add("limit", context.args.get("limit") orelse "10");
    try path.add("offset", context.args.get("offset") orelse "0");
    try context.call(.GET, path.path(), null);
}

fn show(context: *const Context) !void {
    const id = try common.positiveInt(try context.args.requirePositional(2, "project-id"), "project-id");
    const statuses = [_][]const u8{ "Normal", "Archive", "Deleted" };
    for (statuses) |status| {
        var offset: i64 = 0;
        while (true) {
            var path = try query.Builder.init(context.allocator, "/mcp/projects");
            defer path.deinit();
            try path.add("status", status);
            try path.add("limit", "100");
            try path.addInt("offset", offset);
            var response = try context.fetch(.GET, path.path(), null);
            defer response.deinit();
            const code = @intFromEnum(response.status);
            if (code < 200 or code >= 300) return output.finish(&response);
            const document = try std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{});
            defer document.deinit();
            const projects = document.value.object.get("projects") orelse return error.InvalidResponse;
            for (projects.array.items) |candidate| {
                const candidate_id = candidate.object.get("id") orelse continue;
                if (candidate_id == .integer and candidate_id.integer == id) {
                    var result = try json.Object.init(context.allocator);
                    defer result.deinit();
                    try result.boolean("success", true);
                    try result.raw("project", try std.json.Stringify.valueAlloc(context.allocator, candidate, .{}));
                    return context.print(try result.finish());
                }
            }
            const has_more = document.value.object.get("has_more") orelse break;
            if (has_more != .bool or !has_more.bool or projects.array.items.len == 0) break;
            if (document.value.object.get("next_offset")) |next| {
                if (next == .integer) offset = next.integer else offset += @intCast(projects.array.items.len);
            } else offset += @intCast(projects.array.items.len);
        }
    }
    return error.ProjectNotFound;
}

fn simpleProjectGet(context: *const Context, resource: []const u8) !void {
    const id = try common.positiveInt(try context.args.requirePositional(2, "project-id"), "project-id");
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/{s}", .{ id, resource });
    try context.call(.GET, path, null);
}

fn playbook(context: *const Context) !void {
    const id = try common.positiveInt(try context.args.requirePositional(2, "project-id"), "project-id");
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/playbook", .{id});
    const writes = context.args.has("done") or context.args.has("working-rules") or context.args.has("notes") or context.args.has("clear");
    if (!writes) return context.call(.GET, path, null);
    if (context.args.has("clear") and (context.args.has("done") or context.args.has("working-rules") or context.args.has("notes"))) return error.InvalidOptions;
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    if (!context.args.has("clear")) {
        const done = try context.args.getAll(context.allocator, "done");
        if (done.len != 0) try body.strings("definition_of_done", done);
        if (context.args.get("working-rules")) |value| try body.string("working_rules", value);
        if (context.args.get("notes")) |value| try body.string("notes", value);
    }
    try context.call(.PUT, path, try body.finish());
}

fn instructions(context: *const Context) !void {
    const id = try common.positiveInt(try context.args.requirePositional(2, "project-id"), "project-id");
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/instructions", .{id});
    const text = context.args.get("text") orelse return context.call(.GET, path, null);
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("custom_instruction", text);
    if (context.args.get("model")) |value| try body.string("model_selected", value);
    try context.call(.PUT, path, try body.finish());
}

fn projectResource(context: *const Context, resource: []const u8, method: std.http.Method, body: ?[]const u8) !void {
    const id = try common.positiveInt(try context.args.requirePositional(2, "project-id"), "project-id");
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/{s}", .{ id, resource });
    try context.call(method, path, body);
}

fn invite(context: *const Context) !void {
    const id = try common.positiveInt(try context.args.requirePositional(2, "project-id"), "project-id");
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("projectId", id);
    const user = try context.args.require("user");
    if (std.fmt.parseInt(i64, user, 10)) |number| try body.integer("userToAdd", number) else |_| try body.string("userToAdd", user);
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/members", .{id});
    try context.call(.POST, path, try body.finish());
}

fn labels(context: *const Context, project: []const u8) !void {
    _ = try common.positiveInt(project, "project");
    var path = try query.Builder.init(context.allocator, "/mcp/projects");
    defer path.deinit();
    try path.add("limit", "100");
    try path.add("offset", "0");
    try context.call(.GET, path.path(), null);
}

fn createLabel(context: *const Context) !void {
    const project = try common.positiveInt(try context.args.require("project"), "project");
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("name", try context.args.require("name"));
    if (context.args.get("color")) |value| try body.string("color", value);
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/projects/{d}/labels", .{project});
    try context.call(.POST, path, try body.finish());
}

fn archive(context: *const Context) !void {
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.integer("project_id", try common.positiveInt(try context.args.requirePositional(2, "id"), "id"));
    try body.string("status", if (context.args.has("restore")) "Normal" else "Archive");
    try context.call(.POST, "/mcp/projects/archive", try body.finish());
}

fn createBoard(context: *const Context) !void {
    if (context.args.get("manifest")) |manifest_path| {
        return createBoardManifest(context, try common.readFile(context.allocator, manifest_path, 10 * 1024 * 1024));
    }
    if (context.args.has("stdin")) {
        const raw = try std.fs.File.stdin().readToEndAlloc(context.allocator, 10 * 1024 * 1024);
        return createBoardManifest(context, raw);
    }
    const team = try context.args.require("team");
    const title = try context.args.require("title");
    const sections = blk: {
        const supplied = try common.optionList(context, "sections");
        if (supplied.len != 0) break :blk supplied;
        break :blk @as([]const []const u8, &.{ "To Do", "In Progress", "Done" });
    };
    var raw_sections: std.ArrayListUnmanaged(u8) = .{};
    try raw_sections.append(context.allocator, '[');
    for (sections, 0..) |section, index| {
        if (index != 0) try raw_sections.append(context.allocator, ',');
        try raw_sections.appendSlice(context.allocator, "{\"title\":");
        try json.writeString(raw_sections.writer(context.allocator), section);
        try raw_sections.append(context.allocator, '}');
    }
    try raw_sections.append(context.allocator, ']');
    var body = try json.Object.init(context.allocator);
    defer body.deinit();
    try body.string("title", title);
    try body.raw("sections", raw_sections.items);
    if (context.args.get("description")) |value| try body.string("description", value);
    const labels_values = try common.optionList(context, "labels");
    if (labels_values.len != 0) try body.raw("labels", try namedObjects(context, labels_values, "name"));
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/teams/{s}/boards", .{team});
    try context.call(.POST, path, try body.finish());
}

fn createBoardManifest(context: *const Context, raw: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, context.allocator, raw, .{});
    defer parsed.deinit();
    const team_value = parsed.value.object.get("team_id") orelse return error.MissingOption;
    const team = switch (team_value) {
        .string => |value| value,
        .integer => |value| try std.fmt.allocPrint(context.allocator, "{d}", .{value}),
        else => return error.InvalidManifest,
    };
    var body_object = try json.Object.init(context.allocator);
    defer body_object.deinit();
    const title = parsed.value.object.get("title") orelse return error.InvalidManifest;
    if (title != .string) return error.InvalidManifest;
    try body_object.string("title", title.string);
    const sections = parsed.value.object.get("sections") orelse return error.InvalidManifest;
    try body_object.raw("sections", try normalizeNamedArray(context, sections, "title"));
    if (parsed.value.object.get("description")) |value| if (value == .string) try body_object.string("description", value.string);
    if (parsed.value.object.get("labels")) |value| try body_object.raw("labels", try normalizeNamedArray(context, value, "name"));
    if (parsed.value.object.get("tasks")) |value| try body_object.raw("tasks", try std.json.Stringify.valueAlloc(context.allocator, value, .{}));
    if (parsed.value.object.get("source_summary")) |value| if (value == .string) try body_object.string("source_summary", value.string);
    const path = try std.fmt.allocPrint(context.allocator, "/mcp/teams/{s}/boards", .{team});
    try context.call(.POST, path, try body_object.finish());
}

fn namedObjects(context: *const Context, values: []const []const u8, field: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    try result.append(context.allocator, '[');
    for (values, 0..) |value, index| {
        if (index != 0) try result.append(context.allocator, ',');
        var object = try json.Object.init(context.allocator);
        defer object.deinit();
        try object.string(field, value);
        try result.appendSlice(context.allocator, try object.finish());
    }
    try result.append(context.allocator, ']');
    return result.toOwnedSlice(context.allocator);
}

fn normalizeNamedArray(context: *const Context, value: std.json.Value, field: []const u8) ![]const u8 {
    if (value != .array) return error.InvalidManifest;
    var result: std.ArrayListUnmanaged(u8) = .{};
    try result.append(context.allocator, '[');
    for (value.array.items, 0..) |item, index| {
        if (index != 0) try result.append(context.allocator, ',');
        if (item == .string) {
            var object = try json.Object.init(context.allocator);
            defer object.deinit();
            try object.string(field, item.string);
            try result.appendSlice(context.allocator, try object.finish());
        } else {
            try result.appendSlice(context.allocator, try std.json.Stringify.valueAlloc(context.allocator, item, .{}));
        }
    }
    try result.append(context.allocator, ']');
    return result.toOwnedSlice(context.allocator);
}
