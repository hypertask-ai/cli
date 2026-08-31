const std = @import("std");
const args_mod = @import("args.zig");
const config = @import("config.zig");
const Context = @import("command_context.zig").Context;
const output = @import("output.zig");
const router = @import("router.zig");
const token_refresh = @import("token_refresh.zig");

const version = "0.2.0 (zig)";

pub fn main() void {
    run() catch |err| {
        if (!output.responseBodyWasPrinted(err)) {
            std.debug.print("hypertask: {s}\n", .{@errorName(err)});
        }
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
    if (parsed.has("version")) {
        try std.fs.File.stdout().writeAll("hypertask " ++ version ++ "\n");
        return;
    }
    if (parsed.has("help")) return router.printHelp();
    if (parsed.positional.len == 0) return router.printHelp();

    var cfg = try config.load(allocator, parsed.get("token"), parsed.get("api-url"), parsed.get("management-key"));
    defer cfg.deinit();
    const explicit_refresh = parsed.positional.len >= 2 and
        std.mem.eql(u8, parsed.positional[0], "token") and
        std.mem.eql(u8, parsed.positional[1], "refresh");
    if (!explicit_refresh) try token_refresh.maybeRefresh(allocator, &cfg);
    const context = Context{
        .allocator = allocator,
        .args = &parsed,
        .cfg = &cfg,
        .json = !parsed.has("human"),
    };
    try router.dispatch(&context);
}

test {
    _ = @import("args.zig");
    _ = @import("http.zig");
    _ = @import("json_util.zig");
    _ = @import("query.zig");
    _ = @import("token_refresh.zig");
    _ = @import("commands/project.zig");
    _ = @import("commands/task.zig");
    _ = @import("commands/agent.zig");
    _ = @import("commands/messages.zig");
    _ = @import("command_tests.zig");
}
