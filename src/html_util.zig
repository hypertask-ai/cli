const std = @import("std");

pub fn addressesAgent(html: []const u8, agent_id: []const u8, agent_name: []const u8) bool {
    var remaining = html;
    while (std.mem.indexOf(u8, remaining, "<span")) |start| {
        remaining = remaining[start..];
        const end = std.mem.indexOfScalar(u8, remaining, '>') orelse return false;
        const chip = remaining[0 .. end + 1];
        const data_type = attributeValue(chip, "data-type");
        if (data_type != null and std.mem.eql(u8, data_type.?, "mention")) {
            const label = attributeValue(chip, "data-label");
            if (label != null and std.mem.startsWith(u8, label.?, "agent-")) {
                if (std.mem.eql(u8, label.?[6..], agent_id)) return true;
            } else {
                const display_name = attributeValue(chip, "data-id");
                if (display_name != null and agent_name.len != 0 and std.mem.eql(u8, display_name.?, agent_name)) return true;
            }
        }
        remaining = remaining[end + 1 ..];
    }
    return false;
}

fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < tag.len) {
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) index += 1;
        if (index >= tag.len or tag[index] == '>') return null;

        const name_start = index;
        while (index < tag.len and !std.ascii.isWhitespace(tag[index]) and tag[index] != '=' and tag[index] != '>' and tag[index] != '/') index += 1;
        if (index == name_start) {
            index += 1;
            continue;
        }
        const attribute_name = tag[name_start..index];
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) index += 1;
        if (index >= tag.len or tag[index] != '=') continue;
        index += 1;
        while (index < tag.len and std.ascii.isWhitespace(tag[index])) index += 1;
        if (index >= tag.len or (tag[index] != '"' and tag[index] != '\'')) continue;

        const quote = tag[index];
        index += 1;
        const value_start = index;
        while (index < tag.len and tag[index] != quote) index += 1;
        if (index >= tag.len) return null;
        const value = tag[value_start..index];
        index += 1;
        if (std.mem.eql(u8, attribute_name, name)) return value;
    }
    return null;
}

test "mention matching only accepts exact mention identifiers" {
    try std.testing.expect(addressesAgent("<p><span data-type=\"mention\" data-id=\"Dev\" data-label=\"agent-agent-1\">@Dev</span></p>", "agent-1", "Dev"));
    try std.testing.expect(addressesAgent("<span data-type='mention' data-label='agent-agent-1'>@Dev</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<p>agent-1 without a mention chip</p>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span data-type=\"mention\" data-id=\"Other\" data-label=\"agent-agent-10\">@Other</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span data-type=\"mention\" data-id=\"Dev\" data-label=\"agent-agent-10\">@Dev</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span data-type=\"mention\" data-other=\"agent-1\" data-id=\"Other\">@Other</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span xdata-type=\"mention\" data-label=\"agent-agent-1\">@Other</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span data-type=\"mention\" xdata-label=\"agent-agent-1\" data-id=\"Other\">@Other</span>", "agent-1", "Dev"));
    try std.testing.expect(!addressesAgent("<span title=\"data-label='agent-agent-1'\" data-type=\"mention\" data-id=\"Other\">@Other</span>", "agent-1", "Dev"));
}
