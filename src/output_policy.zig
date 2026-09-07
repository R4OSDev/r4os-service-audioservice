const std = @import("std");

pub const capacity = 256;
pub const Id = [64]u8;
pub const automatic: Id = .{0} ** 64;
pub const Candidate = struct {
    id: Id,
    available: bool,
    hdmi: bool,
    active: bool,
};
pub const Reason = enum { preferred, auto_hdmi, auto_analog, preferred_unavailable, none_available, activation_failed };
pub const Resolution = struct { index: ?usize = null, reason: Reason = .none_available };

pub fn validId(id: *const Id) bool {
    const len = std.mem.indexOfScalar(u8, id, 0) orelse return false;
    for (id[0..len]) |byte| if (byte < 0x21 or byte > 0x7e or byte == '=') return false;
    for (id[len..]) |byte| if (byte != 0) return false;
    return true;
}

/// Resolve by persistent identity, independent of enumeration order. A failed
/// replacement retains an available active route. Without one, try at most
/// four routes so a broken controller cannot monopolize the service loop.
pub fn resolve(items: []const Candidate, desired: Id, selector: anytype) Resolution {
    std.debug.assert(items.len <= capacity);
    var excluded = [_]bool{false} ** capacity;
    var previous: ?usize = null;
    for (items, 0..) |item, i| {
        if (item.available and item.active) previous = i;
    }
    for (0..4) |_| {
        var best: ?usize = null;
        var best_score: u32 = 0;
        for (items, 0..) |item, i| {
            if (!item.available or excluded[i]) continue;
            const preferred = desired[0] != 0 and std.mem.eql(u8, &desired, &item.id);
            const score: u32 = if (preferred) 1000 else if (item.hdmi) 100 else if (item.active) 20 else 1;
            if (score > best_score) {
                best = i;
                best_score = score;
            }
        }
        const index = best orelse return .{ .index = previous, .reason = if (previous != null) .activation_failed else .none_available };
        if (items[index].active or selector.activate(index)) {
            return .{ .index = index, .reason = if (desired[0] != 0)
                (if (std.mem.eql(u8, &desired, &items[index].id)) .preferred else .preferred_unavailable)
            else if (items[index].hdmi) .auto_hdmi else .auto_analog };
        }
        if (previous != null) return .{ .index = previous, .reason = .activation_failed };
        excluded[index] = true;
    }
    return .{ .index = previous, .reason = .activation_failed };
}

fn testId(value: []const u8) Id {
    var id = automatic;
    @memcpy(id[0..value.len], value);
    return id;
}

test "persistent identity survives reorder unplug and reconnect with HDMI fallback" {
    const Selector = struct {
        fn activate(_: *@This(), _: usize) bool {
            return true;
        }
    };
    var selector = Selector{};
    var items = [_]Candidate{
        .{ .id = testId("analog"), .available = true, .hdmi = false, .active = true },
        .{ .id = testId("hdmi"), .available = true, .hdmi = true, .active = false },
    };
    const desired = testId("analog");
    try std.testing.expectEqual(@as(?usize, 0), resolve(&items, desired, &selector).index);
    std.mem.swap(Candidate, &items[0], &items[1]);
    try std.testing.expectEqual(@as(?usize, 1), resolve(&items, desired, &selector).index);
    items[1].available = false;
    const fallback = resolve(&items, desired, &selector);
    try std.testing.expectEqual(@as(?usize, 0), fallback.index);
    try std.testing.expectEqual(Reason.preferred_unavailable, fallback.reason);
    items[1].available = true;
    try std.testing.expectEqual(Reason.preferred, resolve(&items, desired, &selector).reason);
    try std.testing.expectEqual(Reason.auto_hdmi, resolve(&items, automatic, &selector).reason);
    items[0].available = false;
    try std.testing.expectEqual(Reason.auto_analog, resolve(&items, automatic, &selector).reason);
}

test "failed switch retains previous route and no-route fallback is bounded" {
    const Selector = struct {
        calls: usize = 0,
        fn activate(self: *@This(), _: usize) bool {
            self.calls += 1;
            return false;
        }
    };
    var selector = Selector{};
    var items = [_]Candidate{.{ .id = testId("a"), .available = true, .hdmi = false, .active = true }} ** 8;
    items[1] = .{ .id = testId("h"), .available = true, .hdmi = true, .active = false };
    const result = resolve(items[0..2], automatic, &selector);
    try std.testing.expectEqual(@as(?usize, 0), result.index);
    try std.testing.expectEqual(Reason.activation_failed, result.reason);
    for (&items) |*item| item.active = false;
    selector.calls = 0;
    try std.testing.expectEqual(Reason.activation_failed, resolve(&items, automatic, &selector).reason);
    try std.testing.expectEqual(@as(usize, 4), selector.calls);
}
