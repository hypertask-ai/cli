const std = @import("std");
const Context = @import("command_context.zig").Context;
const output = @import("output.zig");

const admin = @import("commands/admin.zig");
const agent = @import("commands/agent.zig");
const agents = @import("commands/agents.zig");
const ai = @import("commands/ai.zig");
const auth = @import("commands/auth.zig");
const comment = @import("commands/comment.zig");
const decision = @import("commands/decision.zig");
const draft = @import("commands/draft.zig");
const fields = @import("commands/fields.zig");
const inbox = @import("commands/inbox.zig");
const meta = @import("commands/meta.zig");
const messages = @import("commands/messages.zig");
const pages = @import("commands/pages.zig");
const project = @import("commands/project.zig");
const report = @import("commands/report.zig");
const section = @import("commands/section.zig");
const skills = @import("commands/skills.zig");
const task = @import("commands/task.zig");
const time = @import("commands/time.zig");
const user = @import("commands/user.zig");
const view = @import("commands/view.zig");
const webhook = @import("commands/webhook.zig");

pub fn dispatch(context: *const Context) !void {
    const root = context.args.positionalAt(0) orelse return printHelp(context.allocator, &.{});
    if (std.mem.eql(u8, root, "login")) return auth.login(context);
    if (std.mem.eql(u8, root, "logout")) return auth.logout(context);
    if (std.mem.eql(u8, root, "status")) return auth.status(context);
    if (std.mem.eql(u8, root, "update")) return meta.update(context);
    if (std.mem.eql(u8, root, "context")) return meta.context(context);
    if (std.mem.eql(u8, root, "presence")) return meta.presence(context);
    if (std.mem.eql(u8, root, "capabilities") or std.mem.eql(u8, root, "commands")) return meta.capabilities(context);
    if (std.mem.eql(u8, root, "search")) return task.globalSearch(context);
    if (std.mem.eql(u8, root, "raw")) return meta.raw(context);

    const subcommand = context.args.positionalAt(1) orelse return error.MissingSubcommand;
    if (std.mem.eql(u8, root, "token")) return auth.token(context, subcommand);
    if (std.mem.eql(u8, root, "teams") or std.mem.eql(u8, root, "team")) {
        if (!std.mem.eql(u8, subcommand, "list")) return error.UnknownCommand;
        return meta.teams(context);
    }
    if (std.mem.eql(u8, root, "decision") or std.mem.eql(u8, root, "decisions")) return decision.run(context, subcommand);
    if (std.mem.eql(u8, root, "user")) return user.run(context, subcommand);
    if (std.mem.eql(u8, root, "agent")) return agent.run(context, subcommand);
    if (std.mem.eql(u8, root, "agents")) return agents.run(context, subcommand);
    if (std.mem.eql(u8, root, "messages")) return messages.run(context, subcommand);
    if (std.mem.eql(u8, root, "webhook") or std.mem.eql(u8, root, "webhooks")) return webhook.run(context, subcommand);
    if (std.mem.eql(u8, root, "admin")) {
        const admin_subcommand = context.args.positionalAt(2) orelse return error.MissingSubcommand;
        return admin.run(context, subcommand, admin_subcommand);
    }
    if (std.mem.eql(u8, root, "project") or std.mem.eql(u8, root, "projects")) return project.run(context, subcommand);
    if (std.mem.eql(u8, root, "labels")) return project.labelsCommand(context, subcommand);
    if (std.mem.eql(u8, root, "section") or std.mem.eql(u8, root, "sections")) return section.run(context, subcommand);
    if (std.mem.eql(u8, root, "fields") or std.mem.eql(u8, root, "custom-fields")) return fields.run(context, subcommand);
    if (std.mem.eql(u8, root, "task") or std.mem.eql(u8, root, "tasks")) return task.run(context, subcommand);
    if (std.mem.eql(u8, root, "draft") or std.mem.eql(u8, root, "drafts")) return draft.run(context, subcommand);
    if (std.mem.eql(u8, root, "comment") or std.mem.eql(u8, root, "comments")) return comment.run(context, subcommand);
    if (std.mem.eql(u8, root, "pages") or std.mem.eql(u8, root, "page")) return pages.run(context, subcommand);
    if (std.mem.eql(u8, root, "skills") or std.mem.eql(u8, root, "skill")) return skills.run(context, subcommand);
    if (std.mem.eql(u8, root, "ai")) return ai.run(context, subcommand);
    if (std.mem.eql(u8, root, "inbox")) return inbox.run(context, subcommand);
    if (std.mem.eql(u8, root, "report") or std.mem.eql(u8, root, "reports")) return report.run(context, subcommand);
    if (std.mem.eql(u8, root, "time")) return time.run(context, subcommand);
    if (std.mem.eql(u8, root, "view") or std.mem.eql(u8, root, "views")) return view.run(context, subcommand);
    return error.UnknownCommand;
}

pub fn printHelp(allocator: std.mem.Allocator, path: []const []const u8) !void {
    const help = try renderHelp(allocator, path);
    defer allocator.free(help);
    try output.print(help);
}

fn renderHelp(allocator: std.mem.Allocator, path: []const []const u8) ![]u8 {
    if (path.len == 0) return allocator.dupe(u8,
        \\hypertask 0.2.0 (zig), native Hypertask CLI
        \\
        \\Usage: hypertask [--json] [--token <jwt>] [--api-url <url>] <command> ...
        \\
        \\Run `hypertask capabilities --json` for the complete command and option catalog.
    );

    const catalog = @embedFile("capabilities.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, catalog, .{});
    defer parsed.deinit();

    var command = parsed.value;
    var canonical_path: std.ArrayListUnmanaged([]const u8) = .{};
    defer canonical_path.deinit(allocator);
    for (path) |segment| {
        command = findCommand(command, segment) orelse {
            if ((try arrayField(command, "commands")).len == 0) break;
            return error.UnknownCommand;
        };
        try canonical_path.append(allocator, try stringField(command, "name"));
    }

    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    const writer = result.writer(allocator);

    try writer.print("{s}\n\nUsage: hypertask", .{try stringField(command, "description")});
    for (canonical_path.items) |segment| try writer.print(" {s}", .{segment});

    const arguments = try arrayField(command, "arguments");
    for (arguments) |argument| {
        const name = try stringField(argument, "name");
        const required = try boolField(argument, "required");
        const variadic = try boolField(argument, "variadic");
        if (required) {
            try writer.print(" <{s}{s}>", .{ name, if (variadic) "..." else "" });
        } else {
            try writer.print(" [{s}{s}]", .{ name, if (variadic) "..." else "" });
        }
    }

    const options = try arrayField(command, "options");
    if (options.len != 0) try writer.writeAll(" [options]");
    const commands = try arrayField(command, "commands");
    if (commands.len != 0) try writer.writeAll(" <command>");
    try writer.writeByte('\n');

    if (options.len != 0) {
        try writer.writeAll("\nOptions:\n");
        for (options) |option| {
            try writer.print("  {s}\n      {s}\n", .{
                try stringField(option, "flags"),
                try stringField(option, "description"),
            });
        }
    }

    if (commands.len != 0) {
        try writer.writeAll("\nCommands:\n");
        for (commands) |subcommand| {
            try writer.print("  {s}\n      {s}\n", .{
                try stringField(subcommand, "name"),
                try stringField(subcommand, "description"),
            });
        }
    }

    try writer.writeAll("\n  -h, --help\n      Show help\n");
    return result.toOwnedSlice(allocator);
}

fn findCommand(parent: std.json.Value, name: []const u8) ?std.json.Value {
    const commands = arrayField(parent, "commands") catch return null;
    for (commands) |command| {
        if (std.mem.eql(u8, stringField(command, "name") catch continue, name)) return command;
        const aliases = arrayField(command, "aliases") catch continue;
        for (aliases) |alias| {
            if (alias == .string and std.mem.eql(u8, alias.string, name)) return command;
        }
    }
    return null;
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidCapabilities;
    const field = value.object.get(name) orelse return error.InvalidCapabilities;
    if (field != .string) return error.InvalidCapabilities;
    return field.string;
}

fn boolField(value: std.json.Value, name: []const u8) !bool {
    if (value != .object) return error.InvalidCapabilities;
    const field = value.object.get(name) orelse return error.InvalidCapabilities;
    if (field != .bool) return error.InvalidCapabilities;
    return field.bool;
}

fn arrayField(value: std.json.Value, name: []const u8) ![]const std.json.Value {
    if (value != .object) return error.InvalidCapabilities;
    const field = value.object.get(name) orelse return error.InvalidCapabilities;
    if (field != .array) return error.InvalidCapabilities;
    return field.array.items;
}

test "subcommand help renders command-specific options" {
    const assign_help = try renderHelp(std.testing.allocator, &.{ "tasks", "assign" });
    defer std.testing.allocator.free(assign_help);
    try std.testing.expect(std.mem.indexOf(u8, assign_help, "Usage: hypertask task assign <ticket> [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, assign_help, "--assignee <id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, assign_help, "--self") != null);

    const assign_with_ticket_help = try renderHelp(std.testing.allocator, &.{ "tasks", "assign", "HTPR-6276" });
    defer std.testing.allocator.free(assign_with_ticket_help);
    try std.testing.expectEqualStrings(assign_help, assign_with_ticket_help);

    const unassign_help = try renderHelp(std.testing.allocator, &.{ "tasks", "unassign" });
    defer std.testing.allocator.free(unassign_help);
    try std.testing.expect(std.mem.indexOf(u8, unassign_help, "Usage: hypertask task unassign <ticket> [options]") != null);
    try std.testing.expect(std.mem.indexOf(u8, unassign_help, "--assignee <id>") != null);
    try std.testing.expect(std.mem.indexOf(u8, unassign_help, "--self") == null);
}
