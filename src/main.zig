const std = @import("std");
const config_mod = @import("config.zig");
const http = @import("http.zig");

const VERSION = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // argv0

    var token_override: ?[]const u8 = null;
    var api_url_override: ?[]const u8 = null;
    var json_out = true; // agents: default JSON; --human for tables later
    var positional = std.ArrayListUnmanaged([]const u8){};
    defer positional.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try std.fs.File.stdout().writeAll("htz " ++ VERSION ++ "\n");
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_out = true;
        } else if (std.mem.eql(u8, arg, "--human")) {
            json_out = false;
        } else if (std.mem.eql(u8, arg, "--token")) {
            token_override = args.next() orelse return fail("missing value for --token");
        } else if (std.mem.startsWith(u8, arg, "--token=")) {
            token_override = arg["--token=".len..];
        } else if (std.mem.eql(u8, arg, "--api-url")) {
            api_url_override = args.next() orelse return fail("missing value for --api-url");
        } else if (std.mem.startsWith(u8, arg, "--api-url=")) {
            api_url_override = arg["--api-url=".len..];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            // Pass through command-local options (--project, --section, …)
            // including their following value when present.
            try positional.append(allocator, arg);
            if (!std.mem.eql(u8, arg, "--json") and
                !std.mem.eql(u8, arg, "--human") and
                !std.mem.containsAtLeast(u8, arg, 1, "="))
            {
                // peek: if next token is a value (not another flag), consume it too
                // Can't peek with argsWithAllocator easily — subcommands parse
                // `--flag value` themselves from the remaining positional list.
                // Values after flags are non-dash tokens and fall into the else branch.
            }
        } else {
            try positional.append(allocator, arg);
        }
    }

    if (positional.items.len == 0) {
        try printHelp();
        return;
    }

    var cfg = config_mod.load(allocator, token_override, api_url_override) catch |err| {
        switch (err) {
            error.NoToken => return fail("no token: run Node `hypertask login` once, or pass --token / HT_TOKEN"),
            else => return err,
        }
    };
    defer cfg.deinit();

    const cmd = positional.items[0];
    const rest = positional.items[1..];

    if (std.mem.eql(u8, cmd, "status")) {
        try cmdStatus(allocator, &cfg, json_out);
    } else if (std.mem.eql(u8, cmd, "tasks") or std.mem.eql(u8, cmd, "task")) {
        try cmdTasks(allocator, &cfg, rest, json_out);
    } else if (std.mem.eql(u8, cmd, "comment") or std.mem.eql(u8, cmd, "comments")) {
        try cmdComments(allocator, &cfg, rest, json_out);
    } else if (std.mem.eql(u8, cmd, "project") or std.mem.eql(u8, cmd, "projects")) {
        try cmdProjects(allocator, &cfg, rest, json_out);
    } else if (std.mem.eql(u8, cmd, "section") or std.mem.eql(u8, cmd, "sections")) {
        try cmdSections(allocator, &cfg, rest, json_out);
    } else if (std.mem.eql(u8, cmd, "raw")) {
        try cmdRaw(allocator, &cfg, rest);
    } else {
        return failFmt(allocator, "unknown command: {s}", .{cmd});
    }
}

fn printHelp() !void {
    const help =
        \\htz — native Hypertask CLI (Zig MVP, HTPR-5726)
        \\
        \\Usage: htz [options] <command> ...
        \\
        \\Commands:
        \\  status
        \\  tasks get <ticket> [--project <id>]
        \\  tasks list --project <id>
        \\  tasks create --project <id> --title <text> [--section <name|id>] [--description <text>]
        \\  tasks move <ticket> --section <name|id> [--project <id>]
        \\  tasks update <ticket> [--title ...] [--description ...] [--assignee <id>] [--project <id>]
        \\  comment list <ticket> [--project <id>]
        \\  comment add <ticket> --text <html-or-text> [--project <id>]
        \\  project list
        \\  section list --project <id>
        \\  raw <METHOD> <path> [json-body]   # like ht helper
        \\
        \\Options:
        \\  --token <jwt>     override saved token (also HT_TOKEN)
        \\  --api-url <url>   override API base (default from ~/.hypertask/config.json)
        \\  --json            JSON output (default)
        \\  --human           brief human output
        \\  -h, --help
        \\  -V, --version
        \\
        \\Auth: reads ~/.hypertask/config.json (same file as the Node CLI).
        \\
    ;
    try std.fs.File.stdout().writeAll(help);
}

fn fail(msg: []const u8) noreturn {
    std.fs.File.stderr().writeAll(msg) catch {};
    std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}

fn failFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) noreturn {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch {
        fail("error");
    };
    defer allocator.free(msg);
    fail(msg);
}

fn printJson(body: []const u8) !void {
    const out = std.fs.File.stdout();
    try out.writeAll(body);
    if (body.len == 0 or body[body.len - 1] != '\n') try out.writeAll("\n");
}

fn ensureOk(resp: *http.Response) !void {
    const code = @intFromEnum(resp.status);
    if (code < 200 or code >= 300) {
        try std.fs.File.stderr().writeAll(resp.body);
        try std.fs.File.stderr().writeAll("\n");
        return error.CommandFailed;
    }
}

fn cmdStatus(allocator: std.mem.Allocator, cfg: *const config_mod.Config, json_out: bool) !void {
    _ = allocator;
    if (json_out) {
        // Avoid printing the full token.
        var buf: [512]u8 = undefined;
        const token_preview = if (cfg.token.len > 12) cfg.token[0..12] else cfg.token;
        const line = try std.fmt.bufPrint(&buf, "{{\"authenticated\":true,\"apiUrl\":\"{s}\",\"tokenPreview\":\"{s}...\",\"cli\":\"htz {s}\"}}\n", .{ cfg.api_url, token_preview, VERSION });
        try std.fs.File.stdout().writeAll(line);
    } else {
        try std.fs.File.stdout().writeAll("htz authenticated\n");
    }
}

fn cmdRaw(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    if (rest.len < 2) return fail("usage: htz raw <METHOD> <path> [json-body]");
    const method_s = rest[0];
    const path = rest[1];
    const body: ?[]const u8 = if (rest.len >= 3) rest[2] else null;

    const method: std.http.Method = if (std.ascii.eqlIgnoreCase(method_s, "GET"))
        .GET
    else if (std.ascii.eqlIgnoreCase(method_s, "POST"))
        .POST
    else if (std.ascii.eqlIgnoreCase(method_s, "PUT"))
        .PUT
    else if (std.ascii.eqlIgnoreCase(method_s, "PATCH"))
        .PATCH
    else if (std.ascii.eqlIgnoreCase(method_s, "DELETE"))
        .DELETE
    else
        return fail("unsupported METHOD");

    var resp = try http.request(allocator, cfg, method, path, body);
    defer resp.deinit();
    try printJson(resp.body);
    const code = @intFromEnum(resp.status);
    if (code < 200 or code >= 300) return error.CommandFailed;
}

fn cmdProjects(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8, json_out: bool) !void {
    _ = json_out;
    const sub = if (rest.len > 0) rest[0] else "list";
    if (!std.mem.eql(u8, sub, "list")) return fail("usage: htz project list");
    var resp = try http.get(allocator, cfg, "/mcp/projects");
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn cmdSections(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8, json_out: bool) !void {
    _ = json_out;
    var project_id: ?[]const u8 = null;
    var i: usize = 0;
    const sub = if (rest.len > 0 and !std.mem.startsWith(u8, rest[0], "-")) blk: {
        i = 1;
        break :blk rest[0];
    } else "list";
    if (!std.mem.eql(u8, sub, "list")) return fail("usage: htz section list --project <id>");

    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "--project=")) {
            project_id = a["--project=".len..];
        } else return failFmt(allocator, "unknown arg: {s}", .{a});
    }
    const pid = project_id orelse return fail("--project is required");
    const path = try std.fmt.allocPrint(allocator, "/mcp/projects/{s}/sections", .{pid});
    defer allocator.free(path);
    var resp = try http.get(allocator, cfg, path);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn cmdComments(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8, json_out: bool) !void {
    _ = json_out;
    if (rest.len == 0) return fail("usage: htz comment list|add ...");
    const sub = rest[0];
    if (std.mem.eql(u8, sub, "list")) {
        try commentList(allocator, cfg, rest[1..]);
    } else if (std.mem.eql(u8, sub, "add")) {
        try commentAdd(allocator, cfg, rest[1..]);
    } else return fail("usage: htz comment list|add ...");
}

fn commentList(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var ticket: ?[]const u8 = null;
    var project_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "--project=")) {
            project_id = a["--project=".len..];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return failFmt(allocator, "unknown option: {s}", .{a});
        } else if (ticket == null) {
            ticket = a;
        } else return failFmt(allocator, "unexpected arg: {s}", .{a});
    }
    const t = ticket orelse return fail("ticket required");
    var path_buf: std.ArrayListUnmanaged(u8) = .{};
    defer path_buf.deinit(allocator);
    try path_buf.writer(allocator).print("/mcp/comments?ticket_number={s}", .{t});
    if (project_id) |p| try path_buf.writer(allocator).print("&project_id={s}", .{p});

    var resp = try http.get(allocator, cfg, path_buf.items);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn commentAdd(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var ticket: ?[]const u8 = null;
    var project_id: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if ((std.mem.eql(u8, a, "--text") or std.mem.eql(u8, a, "--body")) and i + 1 < rest.len) {
            i += 1;
            text = rest[i];
        } else if (std.mem.startsWith(u8, a, "--text=")) {
            text = a["--text=".len..];
        } else if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "--project=")) {
            project_id = a["--project=".len..];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return failFmt(allocator, "unknown option: {s}", .{a});
        } else if (ticket == null) {
            ticket = a;
        } else return failFmt(allocator, "unexpected arg: {s}", .{a});
    }
    const t = ticket orelse return fail("ticket required");
    const body_text = text orelse return fail("--text is required");

    var payload: std.ArrayListUnmanaged(u8) = .{};
    defer payload.deinit(allocator);
    var w = payload.writer(allocator);
    try w.writeAll("{\"ticket_number\":");
    try writeJsonString(&w, t);
    try w.writeAll(",\"text\":");
    try writeJsonString(&w, body_text);
    if (project_id) |p| {
        try w.print(",\"project_id\":{s}", .{p});
    }
    try w.writeAll("}");

    var resp = try http.post(allocator, cfg, "/mcp/comments", payload.items);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn cmdTasks(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8, json_out: bool) !void {
    _ = json_out;
    if (rest.len == 0) return fail("usage: htz tasks get|list|create|move|update ...");
    const sub = rest[0];
    if (std.mem.eql(u8, sub, "get")) {
        try tasksGet(allocator, cfg, rest[1..]);
    } else if (std.mem.eql(u8, sub, "list")) {
        try tasksList(allocator, cfg, rest[1..]);
    } else if (std.mem.eql(u8, sub, "create")) {
        try tasksCreate(allocator, cfg, rest[1..]);
    } else if (std.mem.eql(u8, sub, "move")) {
        try tasksMove(allocator, cfg, rest[1..]);
    } else if (std.mem.eql(u8, sub, "update")) {
        try tasksUpdate(allocator, cfg, rest[1..]);
    } else return fail("usage: htz tasks get|list|create|move|update ...");
}

fn tasksGet(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var ticket: ?[]const u8 = null;
    var project_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "--project=")) {
            project_id = a["--project=".len..];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return failFmt(allocator, "unknown option: {s}", .{a});
        } else if (ticket == null) {
            ticket = a;
        } else return failFmt(allocator, "unexpected arg: {s}", .{a});
    }
    const t = ticket orelse return fail("ticket required");
    var path_buf: std.ArrayListUnmanaged(u8) = .{};
    defer path_buf.deinit(allocator);
    try path_buf.writer(allocator).print("/mcp/tasks?ticket_number={s}", .{t});
    if (project_id) |p| try path_buf.writer(allocator).print("&project_id={s}", .{p});

    var resp = try http.get(allocator, cfg, path_buf.items);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn tasksList(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var project_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "--project=")) {
            project_id = a["--project=".len..];
        } else return failFmt(allocator, "unknown arg: {s}", .{a});
    }
    const pid = project_id orelse return fail("--project is required");
    const path = try std.fmt.allocPrint(allocator, "/mcp/tasks?project_id={s}&limit=50", .{pid});
    defer allocator.free(path);
    var resp = try http.get(allocator, cfg, path);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn tasksCreate(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var project_id: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var section: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.eql(u8, a, "--title") and i + 1 < rest.len) {
            i += 1;
            title = rest[i];
        } else if (std.mem.eql(u8, a, "--description") and i + 1 < rest.len) {
            i += 1;
            description = rest[i];
        } else if (std.mem.eql(u8, a, "--section") and i + 1 < rest.len) {
            i += 1;
            section = rest[i];
        } else return failFmt(allocator, "unknown arg: {s}", .{a});
    }
    const pid = project_id orelse return fail("--project is required");
    const tit = title orelse return fail("--title is required");

    var section_id: ?i64 = null;
    if (section) |sec| {
        section_id = try resolveSectionId(allocator, cfg, pid, sec);
    }

    var payload: std.ArrayListUnmanaged(u8) = .{};
    defer payload.deinit(allocator);
    var w = payload.writer(allocator);
    try w.print("{{\"project_id\":{s},\"title\":", .{pid});
    try writeJsonString(&w, tit);
    if (description) |d| {
        try w.writeAll(",\"description\":");
        try writeJsonString(&w, d);
    }
    if (section_id) |sid| {
        try w.print(",\"section_id\":{d}", .{sid});
    }
    try w.writeAll("}");

    var resp = try http.post(allocator, cfg, "/mcp/tasks/create", payload.items);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn tasksMove(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var ticket: ?[]const u8 = null;
    var section: ?[]const u8 = null;
    var project_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--section") and i + 1 < rest.len) {
            i += 1;
            section = rest[i];
        } else if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return failFmt(allocator, "unknown option: {s}", .{a});
        } else if (ticket == null) {
            ticket = a;
        } else return failFmt(allocator, "unexpected arg: {s}", .{a});
    }
    const t = ticket orelse return fail("ticket required");
    const sec = section orelse return fail("--section is required");

    // Resolve project from task if not provided.
    var pid_owned: ?[]u8 = null;
    defer if (pid_owned) |p| allocator.free(p);
    const pid = project_id orelse blk: {
        const path = try std.fmt.allocPrint(allocator, "/mcp/tasks?ticket_number={s}", .{t});
        defer allocator.free(path);
        var resp = try http.get(allocator, cfg, path);
        defer resp.deinit();
        try ensureOk(&resp);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
        defer parsed.deinit();
        const tasks = parsed.value.object.get("tasks") orelse return fail("task not found");
        if (tasks != .array or tasks.array.items.len == 0) return fail("task not found");
        const task = tasks.array.items[0];
        const pid_val = task.object.get("projectId") orelse return fail("task missing projectId");
        const pid_num = switch (pid_val) {
            .integer => |n| n,
            else => return fail("bad projectId"),
        };
        pid_owned = try std.fmt.allocPrint(allocator, "{d}", .{pid_num});
        break :blk pid_owned.?;
    };

    const section_id = try resolveSectionId(allocator, cfg, pid, sec);

    var payload: std.ArrayListUnmanaged(u8) = .{};
    defer payload.deinit(allocator);
    var w = payload.writer(allocator);
    try w.writeAll("{\"ticket_number\":");
    try writeJsonString(&w, t);
    try w.print(",\"sectionId\":{d}}}", .{section_id});

    var resp = try http.post(allocator, cfg, "/mcp/tasks/update", payload.items);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn tasksUpdate(allocator: std.mem.Allocator, cfg: *const config_mod.Config, rest: []const []const u8) !void {
    var ticket: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var assignee: ?[]const u8 = null;
    var project_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--title") and i + 1 < rest.len) {
            i += 1;
            title = rest[i];
        } else if (std.mem.eql(u8, a, "--description") and i + 1 < rest.len) {
            i += 1;
            description = rest[i];
        } else if (std.mem.eql(u8, a, "--assignee") and i + 1 < rest.len) {
            i += 1;
            assignee = rest[i];
        } else if (std.mem.eql(u8, a, "--project") and i + 1 < rest.len) {
            i += 1;
            project_id = rest[i];
        } else if (std.mem.startsWith(u8, a, "-")) {
            return failFmt(allocator, "unknown option: {s}", .{a});
        } else if (ticket == null) {
            ticket = a;
        } else return failFmt(allocator, "unexpected arg: {s}", .{a});
    }
    const t = ticket orelse return fail("ticket required");
    if (title == null and description == null and assignee == null) {
        return fail("provide at least one of --title --description --assignee");
    }

    var payload: std.ArrayListUnmanaged(u8) = .{};
    defer payload.deinit(allocator);
    var w = payload.writer(allocator);
    try w.writeAll("{\"ticket_number\":");
    try writeJsonString(&w, t);
    if (project_id) |p| try w.print(",\"project_id\":{s}", .{p});
    if (title) |tit| {
        try w.writeAll(",\"title\":");
        try writeJsonString(&w, tit);
    }
    if (description) |d| {
        try w.writeAll(",\"description\":");
        try writeJsonString(&w, d);
    }
    if (assignee) |a| {
        try w.print(",\"assignee\":[{s}]", .{a});
    }
    try w.writeAll("}");

    var resp = try http.post(allocator, cfg, "/mcp/tasks/update", payload.items);
    defer resp.deinit();
    try ensureOk(&resp);
    try printJson(resp.body);
}

fn resolveSectionId(allocator: std.mem.Allocator, cfg: *const config_mod.Config, project_id: []const u8, section: []const u8) !i64 {
    // numeric id?
    if (std.fmt.parseInt(i64, section, 10)) |id| {
        return id;
    } else |_| {}

    const path = try std.fmt.allocPrint(allocator, "/mcp/projects/{s}/sections", .{project_id});
    defer allocator.free(path);
    var resp = try http.get(allocator, cfg, path);
    defer resp.deinit();
    try ensureOk(&resp);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{});
    defer parsed.deinit();
    const sections = parsed.value.object.get("sections") orelse return fail("no sections in response");
    if (sections != .array) return fail("bad sections response");

    for (sections.array.items) |item| {
        const title_val = item.object.get("section_title") orelse continue;
        const title = switch (title_val) {
            .string => |s| s,
            else => continue,
        };
        if (std.ascii.eqlIgnoreCase(title, section)) {
            const id_val = item.object.get("id") orelse continue;
            return switch (id_val) {
                .integer => |n| n,
                else => continue,
            };
        }
    }
    return failFmt(allocator, "section not found: {s}", .{section});
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    const esc = [_]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xf] };
                    try w.writeAll(&esc);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

test "json string escapes" {
    var list: std.ArrayListUnmanaged(u8) = .{};
    defer list.deinit(std.testing.allocator);
    var w = list.writer(std.testing.allocator);
    try writeJsonString(&w, "a\"b\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\n\"", list.items);
}
