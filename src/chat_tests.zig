// Keep the module root at src/ so chat can import the shared command modules.
test {
    _ = @import("commands/chat.zig");
}
