const std = @import("std");
const builtin = @import("builtin");

pub const refusal = "hypertask: helpers never write to the board; report to your runner\n";
pub const testing = if (builtin.is_test) struct {
    pub var helper: ?bool = null;
} else struct {};

pub fn isHelper(allocator: std.mem.Allocator) bool {
    if (builtin.is_test) return testing.helper orelse false;
    const marker = std.process.getEnvVarOwned(allocator, "VCC_HELPER") catch null;
    defer if (marker) |value| allocator.free(value);
    if (marker != null and std.mem.eql(u8, marker.?, "1")) return true;
    if (builtin.os.tag != .linux) return false;
    const root = std.process.getEnvVarOwned(allocator, "VCC_HELPER_PROC_ROOT") catch null;
    defer if (root) |value| allocator.free(value);
    return detect(allocator, marker, if (root != null and root.?.len != 0) root.? else "/proc", @intCast(std.os.linux.getppid()));
}

fn detect(allocator: std.mem.Allocator, marker: ?[]const u8, root: []const u8, parent_pid: u32) bool {
    if (marker != null and std.mem.eql(u8, marker.?, "1")) return true;
    var proc = std.fs.cwd().openDir(root, .{}) catch return false;
    defer proc.close();
    var pid = parent_pid;
    while (pid > 1) {
        var path_buffer: [64]u8 = undefined;
        const comm_path = std.fmt.bufPrint(&path_buffer, "{d}/comm", .{pid}) catch return false;
        const comm = proc.readFileAlloc(allocator, comm_path, 1024) catch return false;
        defer allocator.free(comm);
        if (std.mem.eql(u8, std.mem.trimEnd(u8, comm, "\n"), "hax")) {
            const cmdline_path = std.fmt.bufPrint(&path_buffer, "{d}/cmdline", .{pid}) catch return false;
            if (proc.readFileAlloc(allocator, cmdline_path, 1024 * 1024)) |cmdline| {
                defer allocator.free(cmdline);
                var args = std.mem.splitScalar(u8, cmdline, 0);
                while (args.next()) |arg| {
                    if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--prompt") or std.mem.eql(u8, arg, "--print")) return true;
                }
            } else |_| {}
        }
        const stat_path = std.fmt.bufPrint(&path_buffer, "{d}/stat", .{pid}) catch return false;
        const stat = proc.readFileAlloc(allocator, stat_path, 64 * 1024) catch return false;
        defer allocator.free(stat);
        const end = std.mem.lastIndexOf(u8, stat, ") ") orelse return false;
        var fields = std.mem.tokenizeAny(u8, stat[end + 2 ..], " \t\r\n");
        _ = fields.next() orelse return false;
        const parent = std.fmt.parseInt(u32, fields.next() orelse return false, 10) catch return false;
        if (parent == pid) break;
        pid = parent;
    }
    return false;
}

pub fn isRead(method: std.http.Method, path: []const u8) bool {
    if (method == .GET) return true;
    if (method != .POST) return false;
    // Generation does not apply changes; apply uses separate mutation endpoints.
    // Refresh rotates credentials, not board state.
    return std.mem.eql(u8, path, "/mcp/ai/improve") or
        std.mem.eql(u8, path, "/mcp/ai/task-writer") or
        std.mem.eql(u8, path, "/mcp/token/refresh");
}

pub fn checkUrl(allocator: std.mem.Allocator, method: std.http.Method, url: []const u8) !void {
    if (method == .GET) return;
    var path: []const u8 = "";
    if (std.Uri.parse(url)) |uri| {
        // Check the actual destination too: a query in --api-url must not
        // disguise a mutation as an allow-listed logical path.
        if (uri.query == null and uri.fragment == null) {
            path = switch (uri.path) {
                .raw, .percent_encoded => |value| value,
            };
            if (std.mem.startsWith(u8, path, "/api/")) path = path[4..];
        }
    } else |_| {}
    try check(allocator, method, path);
}

pub fn check(allocator: std.mem.Allocator, method: std.http.Method, path: []const u8) !void {
    if (isRead(method, path) or !isHelper(allocator)) return;
    if (builtin.is_test) return error.HelperWriteForbidden;
    // Exit here because some commands intentionally catch HTTP failures.
    std.fs.File.stderr().writeAll(refusal) catch {};
    std.process.exit(3);
}

test "helper env marker is exactly one even with unreadable proc" {
    try std.testing.expect(detect(std.testing.allocator, "1", "missing-proc", 42));
    for ([_]?[]const u8{ null, "", "0", "true", "11" }) |marker| {
        try std.testing.expect(!detect(std.testing.allocator, marker, "missing-proc", 42));
    }
}

test "helper ancestry handles spaces and parentheses and exact prompt arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("42");
    try tmp.dir.makePath("12");
    try tmp.dir.writeFile(.{ .sub_path = "42/comm", .data = "shell (with spaces)\n" });
    try tmp.dir.writeFile(.{ .sub_path = "42/stat", .data = "42 (shell (with ) spaces)) S 12 0 0\n" });
    try tmp.dir.writeFile(.{ .sub_path = "12/comm", .data = "hax\n" });
    try tmp.dir.writeFile(.{ .sub_path = "12/stat", .data = "12 (hax) S 1 0 0\n" });
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    for ([_][]const u8{ "hax\x00-p\x00prompt\x00", "hax\x00--prompt\x00prompt\x00", "hax\x00--print\x00" }) |cmdline| {
        try tmp.dir.writeFile(.{ .sub_path = "12/cmdline", .data = cmdline });
        try std.testing.expect(detect(std.testing.allocator, null, root, 42));
    }
    for ([_][]const u8{ "hax\x00", "hax\x00-prompt\x00", "hax\x00--prompt=x\x00", "hax\x00text -p\x00" }) |cmdline| {
        try tmp.dir.writeFile(.{ .sub_path = "12/cmdline", .data = cmdline });
        try std.testing.expect(!detect(std.testing.allocator, null, root, 42));
    }
    try tmp.dir.writeFile(.{ .sub_path = "12/cmdline", .data = "hax\x00-p\x00" });
    try tmp.dir.writeFile(.{ .sub_path = "12/comm", .data = "not-hax\n" });
    try std.testing.expect(!detect(std.testing.allocator, null, root, 42));
    try tmp.dir.writeFile(.{ .sub_path = "42/stat", .data = "42 (shell) S 42 0\n" });
    try std.testing.expect(!detect(std.testing.allocator, null, root, 42));
    try tmp.dir.writeFile(.{ .sub_path = "42/stat", .data = "malformed" });
    try std.testing.expect(!detect(std.testing.allocator, null, root, 42));
}

test "helper URL classification cannot be bypassed by API base queries or path aliases" {
    testing.helper = true;
    defer testing.helper = null;
    for ([_][]const u8{ "http://localhost/api/mcp/token/refresh", "http://localhost/mcp/ai/improve", "http://localhost/api/mcp/ai/task-writer" }) |url| {
        try checkUrl(std.testing.allocator, .POST, url);
    }
    for ([_][]const u8{ "not-a-url", "http://localhost/api/mcp/tasks/update?x=/mcp/token/refresh", "http://localhost/api/mcp/token/refresh?x=1", "http://localhost/api/mcp/token/refresh#fragment", "http://localhost/api/mcp/tasks/../token/refresh" }) |url| {
        try std.testing.expectError(error.HelperWriteForbidden, checkUrl(std.testing.allocator, .POST, url));
    }
}

test "helper read exceptions are exact POST paths and never mutation methods" {
    try std.testing.expect(isRead(.GET, "/mcp/search?q=test"));
    for ([_][]const u8{ "/mcp/token/refresh", "/mcp/ai/improve", "/mcp/ai/task-writer" }) |path| {
        try std.testing.expect(isRead(.POST, path));
        try std.testing.expect(!isRead(.DELETE, path));
        try std.testing.expect(!isRead(.PATCH, path));
    }
    for ([_][]const u8{ "/mcp/tasks/update", "/mcp/comments", "/mcp/token/refresh/extra", "/mcp/token/refresh?x=1", "/mcp/ai/improve/../tasks/update" }) |path| {
        try std.testing.expect(!isRead(.POST, path));
    }
}
