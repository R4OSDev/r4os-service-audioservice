const std = @import("std");

pub const default_volume: u32 = 0x0001_0000;
pub const schema = "AUDSVC_MASTER";

pub const State = struct {
    selected_volume_fixed: u32 = default_volume,
    last_audible_volume_fixed: u32 = default_volume,
    muted: bool = false,
    revision: u64 = 1,

    pub fn effectiveVolume(self: State) u32 {
        return if (self.muted) 0 else self.selected_volume_fixed;
    }
};

pub const Update = struct {
    set_volume: bool = false,
    fixed_volume: u32 = default_volume,
    set_muted: bool = false,
    muted: bool = false,
};

pub const Persisted = struct {
    selected_volume_fixed: u32 = default_volume,
    last_audible_volume_fixed: u32 = default_volume,
    muted: bool = false,
};

/// Applies the explicit append-only master contract. A positive volume change
/// makes the output audible, unless the same request explicitly asks for mute.
pub fn applyExplicit(state: *State, update: Update) bool {
    const before = state.*;
    if (update.set_volume) {
        state.selected_volume_fixed = update.fixed_volume;
        if (update.fixed_volume != 0) {
            state.last_audible_volume_fixed = update.fixed_volume;
            state.muted = false;
        }
    }
    if (update.set_muted) {
        if (update.muted) {
            if (state.selected_volume_fixed != 0) state.last_audible_volume_fixed = state.selected_volume_fixed;
            state.muted = true;
        } else {
            if (state.selected_volume_fixed == 0) {
                state.selected_volume_fixed = if (state.last_audible_volume_fixed != 0) state.last_audible_volume_fixed else default_volume;
            }
            state.muted = false;
        }
    }
    return finishChange(state, before);
}

/// Preserves compatibility with the original SetMasterVolume operation: it
/// changes the selected gain but never changes an explicit mute state.
pub fn applyLegacyVolume(state: *State, fixed_volume: u32) bool {
    const before = state.*;
    state.selected_volume_fixed = fixed_volume;
    if (fixed_volume != 0) state.last_audible_volume_fixed = fixed_volume;
    return finishChange(state, before);
}

pub fn restore(state: *State, persisted: Persisted) void {
    state.selected_volume_fixed = persisted.selected_volume_fixed;
    state.last_audible_volume_fixed = if (persisted.last_audible_volume_fixed != 0)
        persisted.last_audible_volume_fixed
    else if (persisted.selected_volume_fixed != 0)
        persisted.selected_volume_fixed
    else
        default_volume;
    state.muted = persisted.muted;
    state.revision = 1;
}

pub fn snapshot(state: State) Persisted {
    return .{
        .selected_volume_fixed = state.selected_volume_fixed,
        .last_audible_volume_fixed = state.last_audible_volume_fixed,
        .muted = state.muted,
    };
}

pub fn encode(persisted: Persisted, out: []u8) ?[]const u8 {
    return std.fmt.bufPrint(
        out,
        "\xEF\xBB\xBFR4S_FORMAT=1\r\nSCHEMA=" ++ schema ++ "\r\nVOLUME_FIXED={d}\r\nMUTED={s}\r\nLAST_AUDIBLE_FIXED={d}\r\n",
        .{ persisted.selected_volume_fixed, if (persisted.muted) "true" else "false", persisted.last_audible_volume_fixed },
    ) catch null;
}

pub fn parse(bytes: []const u8) ?Persisted {
    var format: ?u32 = null;
    var parsed_schema: ?[]const u8 = null;
    var selected: ?u32 = null;
    var muted: ?bool = null;
    var last_audible: ?u32 = null;
    var rest = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    while (rest.len != 0) {
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var line = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
        if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = std.mem.trim(u8, line, " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse return null;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(key, "R4S_FORMAT")) {
            if (format != null) return null;
            format = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.ascii.eqlIgnoreCase(key, "SCHEMA")) {
            if (parsed_schema != null) return null;
            parsed_schema = value;
        } else if (std.ascii.eqlIgnoreCase(key, "VOLUME_FIXED")) {
            if (selected != null) return null;
            selected = std.fmt.parseInt(u32, value, 10) catch return null;
        } else if (std.ascii.eqlIgnoreCase(key, "MUTED")) {
            if (muted != null) return null;
            muted = parseBool(value) orelse return null;
        } else if (std.ascii.eqlIgnoreCase(key, "LAST_AUDIBLE_FIXED")) {
            if (last_audible != null) return null;
            last_audible = std.fmt.parseInt(u32, value, 10) catch return null;
        }
    }
    if (format != 1 or parsed_schema == null or !std.ascii.eqlIgnoreCase(parsed_schema.?, schema)) return null;
    const value = Persisted{
        .selected_volume_fixed = selected orelse return null,
        .last_audible_volume_fixed = last_audible orelse return null,
        .muted = muted orelse return null,
    };
    if (value.last_audible_volume_fixed == 0) return null;
    return value;
}

fn finishChange(state: *State, before: State) bool {
    const changed = state.selected_volume_fixed != before.selected_volume_fixed or
        state.last_audible_volume_fixed != before.last_audible_volume_fixed or
        state.muted != before.muted;
    if (changed) {
        state.revision +%= 1;
        if (state.revision == 0) state.revision = 1;
    }
    return changed;
}

fn parseBool(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return null;
}

test "explicit volume and mute preserve the last audible selection" {
    var state = State{};
    try std.testing.expect(applyExplicit(&state, .{ .set_muted = true, .muted = true }));
    try std.testing.expect(state.muted);
    try std.testing.expectEqual(@as(u32, 0), state.effectiveVolume());
    try std.testing.expect(applyExplicit(&state, .{ .set_volume = true, .fixed_volume = 0x4000 }));
    try std.testing.expect(!state.muted);
    try std.testing.expectEqual(@as(u32, 0x4000), state.last_audible_volume_fixed);
    try std.testing.expect(applyExplicit(&state, .{ .set_volume = true, .fixed_volume = 0, .set_muted = true, .muted = true }));
    try std.testing.expect(applyExplicit(&state, .{ .set_muted = true, .muted = false }));
    try std.testing.expectEqual(@as(u32, 0x4000), state.selected_volume_fixed);
}

test "legacy master volume never clears explicit mute" {
    var state = State{ .muted = true };
    try std.testing.expect(applyLegacyVolume(&state, 0x8000));
    try std.testing.expect(state.muted);
    try std.testing.expectEqual(@as(u32, 0), state.effectiveVolume());
}

test "configuration round trips and rejects corrupt required fields" {
    const expected = Persisted{ .selected_volume_fixed = 32768, .last_audible_volume_fixed = 49152, .muted = true };
    var bytes: [256]u8 = undefined;
    const encoded = encode(expected, bytes[0..]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, parse(encoded).?);
    try std.testing.expect(parse("R4S_FORMAT=1\r\nSCHEMA=AUDSVC_MASTER\r\nMUTED=true\r\n") == null);
    try std.testing.expect(parse("R4S_FORMAT=1\r\nSCHEMA=AUDSVC_MASTER\r\nVOLUME_FIXED=x\r\nMUTED=true\r\nLAST_AUDIBLE_FIXED=1\r\n") == null);
}
