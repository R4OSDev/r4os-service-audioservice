const std = @import("std");

pub const Owner = struct { id: u32, generation: u64 };
pub const Record = struct { owner: Owner, running: bool };
pub const Page = struct { records: []const Record, complete: bool };

/// One inventory traversal for the whole cleanup round. A zero expected
/// generation is used only to bind a newly opened stream to its live owner.
/// Incomplete/changed inventories never authorize closing an absent client.
pub fn collectRunning(owners: []const Owner, generations: []u64, reader: anytype) bool {
    if (owners.len != generations.len) return false;
    @memset(generations, 0);
    if (owners.len == 0) return true;
    if (!reader.begin()) return false;
    for (0..128) |_| {
        const page = reader.next() orelse return false;
        for (page.records) |record| {
            if (!record.running or record.owner.id == 0 or record.owner.generation == 0) continue;
            for (owners, generations) |owner, *generation| {
                if (owner.id == record.owner.id and (owner.generation == 0 or owner.generation == record.owner.generation))
                    generation.* = record.owner.generation;
            }
        }
        if (page.complete) return true;
        var all_running = true;
        for (generations) |generation| all_running = all_running and generation != 0;
        if (all_running) return true; // no absence decisions remain
        if (page.records.len == 0) return false;
    }
    return false;
}

pub fn matches(stored_client_id: u32, stored_stream_id: u32, client_id: u32, stream_id: u32) bool {
    return client_id != 0 and stored_client_id == client_id and stored_stream_id == stream_id;
}

pub fn clientIsRunning(client_id: u32, running_client_ids: []const u32) bool {
    if (client_id == 0) return false;
    for (running_client_ids) |running_id| {
        if (running_id == client_id) return true;
    }
    return false;
}

pub fn runningRecordMatches(client_id: u32, record_client_id: u32, record_state: u8, running_state: u8) bool {
    return client_id != 0 and client_id == record_client_id and record_state == running_state;
}

pub fn isSilence(data: []const u8) bool {
    for (data) |sample_byte| {
        if (sample_byte != 0) return false;
    }
    return true;
}

test "stream access requires both client and stream identity" {
    try std.testing.expect(matches(17, 42, 17, 42));
    try std.testing.expect(!matches(17, 42, 18, 42));
    try std.testing.expect(!matches(17, 42, 17, 43));
    try std.testing.expect(!matches(0, 42, 0, 42));
}

test "dead clients are distinguishable from running clients" {
    const running = [_]u32{ 3, 8, 13 };
    try std.testing.expect(clientIsRunning(8, running[0..]));
    try std.testing.expect(!clientIsRunning(9, running[0..]));
    try std.testing.expect(!clientIsRunning(0, running[0..]));
    try std.testing.expect(runningRecordMatches(8, 8, 0, 0));
    try std.testing.expect(!runningRecordMatches(8, 8, 1, 0));
}

test "s16le silence is detected without manufacturing payload" {
    const silence = [_]u8{0} ** 16;
    var signal = silence;
    signal[9] = 1;
    try std.testing.expect(isSilence(silence[0..]));
    try std.testing.expect(!isSilence(signal[0..]));
}

test "one paged cleanup serves duplicate owners and rejects reused IDs and incomplete inventories" {
    const Reader = struct {
        records: []const Record,
        begins: usize = 0,
        reads: usize = 0,
        failed: bool = false,
        complete: bool = true,
        fn begin(self: *@This()) bool {
            self.begins += 1;
            return true;
        }
        fn next(self: *@This()) ?Page {
            self.reads += 1;
            if (self.failed or self.reads > 1) return null;
            return .{ .records = self.records, .complete = self.complete };
        }
    };
    const owners = [_]Owner{ .{ .id = 7, .generation = 11 }, .{ .id = 7, .generation = 11 }, .{ .id = 8, .generation = 12 }, .{ .id = 9, .generation = 13 } };
    const records = [_]Record{
        .{ .owner = .{ .id = 7, .generation = 11 }, .running = true },
        .{ .owner = .{ .id = 8, .generation = 99 }, .running = true }, // reused ID
        .{ .owner = .{ .id = 9, .generation = 13 }, .running = false },
    };
    var generations: [owners.len]u64 = undefined;
    var reader = Reader{ .records = &records };
    try std.testing.expect(collectRunning(&owners, &generations, &reader));
    try std.testing.expectEqualSlices(u64, &.{ 11, 11, 0, 0 }, &generations);
    try std.testing.expectEqual(@as(usize, 1), reader.begins);
    try std.testing.expectEqual(@as(usize, 1), reader.reads);
    reader = .{ .records = &records, .complete = false };
    try std.testing.expect(!collectRunning(&owners, &generations, &reader));
    reader = .{ .records = &records, .failed = true };
    try std.testing.expect(!collectRunning(&owners, &generations, &reader));
    reader = .{ .records = &records };
    var opened: [1]u64 = undefined;
    try std.testing.expect(collectRunning(&.{.{ .id = 8, .generation = 0 }}, &opened, &reader));
    try std.testing.expectEqual(@as(u64, 99), opened[0]);
    const duplicates = [_]Owner{.{ .id = 7, .generation = 11 }} ** 16;
    var duplicate_generations: [16]u64 = undefined;
    reader = .{ .records = &records };
    try std.testing.expect(collectRunning(&duplicates, &duplicate_generations, &reader));
    try std.testing.expectEqual(@as(usize, 1), reader.begins);
    try std.testing.expectEqual(@as(usize, 1), reader.reads);
    std.debug.print("AUDSVCWORK streams=16 owner=one previous_record_queries=16 snapshot_begins={d} page_queries={d}\n", .{ reader.begins, reader.reads });
}
