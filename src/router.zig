const std = @import("std");
const Context = @import("command_context.zig").Context;
const output = @import("output.zig");

const admin = @import("commands/admin.zig");
const agents = @import("commands/agents.zig");
const ai = @import("commands/ai.zig");
const auth = @import("commands/auth.zig");
const comment = @import("commands/comment.zig");
const decision = @import("commands/decision.zig");
const draft = @import("commands/draft.zig");
const fields = @import("commands/fields.zig");
const inbox = @import("commands/inbox.zig");
const meta = @import("commands/meta.zig");
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
    const root = context.args.positionalAt(0) orelse return printHelp();
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
    if (std.mem.eql(u8, root, "agents")) return agents.run(context, subcommand);
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

pub fn printHelp() !void {
    try output.print(
        \\htz 0.2.0-zig, native Hypertask CLI
        \\
        \\Usage: htz [--json] [--token <jwt>] [--api-url <url>] <command> ...
        \\
        \\Run `htz capabilities --json` for the complete command and option catalog.
    );
}
