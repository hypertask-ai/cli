const std = @import("std");
const args_mod = @import("args.zig");
const config = @import("config.zig");
const Context = @import("command_context.zig").Context;
const option_validate = @import("option_validate.zig");
const output = @import("output.zig");
const router = @import("router.zig");
const error_reports = @import("error_reports.zig");
const token_refresh = @import("token_refresh.zig");

const version = "0.2.27 (zig)";

pub fn main() void {
    run() catch |err| {
        output.printFailure(err);
        std.process.exit(output.exitCode(err));
    };
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var process_args = try std.process.argsWithAllocator(allocator);
    defer process_args.deinit();
    _ = process_args.next();
    var raw: std.ArrayListUnmanaged([]const u8) = .{};
    defer raw.deinit(allocator);
    while (process_args.next()) |value| try raw.append(allocator, value);

    var parsed = try args_mod.parse(allocator, raw.items);
    defer parsed.deinit();
    try option_validate.rejectUnknownOptions(allocator, &parsed);
    try parsed.requireValues();
    if (parsed.hasFlag("version") or (parsed.has("version") and parsed.positional.len == 0)) {
        try std.fs.File.stdout().writeAll("hypertask " ++ version ++ "\n");
        return;
    }
    if (parsed.positional.len == 0) return router.printHelp(allocator, &.{});
    try router.validateCommandPath(allocator, parsed.positional, !parsed.has("help"));
    if (parsed.has("help")) return router.printHelp(allocator, parsed.positional);

    const root = parsed.positional[0];
    const needs_no_token = std.mem.eql(u8, root, "capabilities") or std.mem.eql(u8, root, "commands") or std.mem.eql(u8, root, "login");
    var cfg = if (needs_no_token)
        try config.loadAllowingEmptyToken(allocator, parsed.get("token"), parsed.get("api-url"), parsed.get("management-key"))
    else
        try config.load(allocator, parsed.get("token"), parsed.get("api-url"), parsed.get("management-key"));
    defer cfg.deinit();
    errdefer |err| error_reports.report(allocator, &parsed, &cfg, err, version);
    var client = std.http.Client{ .allocator = std.heap.page_allocator };
    defer client.deinit();
    const explicit_refresh = parsed.positional.len >= 2 and
        std.mem.eql(u8, parsed.positional[0], "token") and
        std.mem.eql(u8, parsed.positional[1], "refresh");
    if (!explicit_refresh) try token_refresh.maybeRefresh(&client, allocator, &cfg);
    const context = Context{
        .client = &client,
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = !parsed.has("human"),
    };
    try router.dispatch(&context);
}

test {
    _ = @import("error_reports.zig");
    _ = @import("args.zig");
    _ = @import("http.zig");
    _ = @import("helper_guard.zig");
    _ = @import("improve_command.zig");
    _ = @import("json_util.zig");
    _ = @import("option_validate.zig");
    _ = @import("query.zig");
    _ = @import("list_query.zig");
    _ = @import("token_refresh.zig");
    _ = @import("commands/project.zig");
    _ = @import("commands/task.zig");
    _ = @import("commands/agent.zig");
    _ = @import("commands/agent_dev.zig");
    _ = @import("commands/inbox.zig");
    _ = @import("commands/messages.zig");
    _ = @import("command_tests.zig");
}
