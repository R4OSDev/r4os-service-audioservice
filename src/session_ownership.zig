const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const program_instance_state_running: u8 = 0;

pub const Owner = struct { id: u32, generation: u64 };
pub const Record = struct { owner: Owner, running: bool };
pub const Page = struct { records: []const Record, complete: bool };

pub const ClientInventory = struct {
    ctx: *const r4os.r4sys.Context,
    cursor: abi.ProgramInventoryCursor = .{},
    items: [16]abi.ProgramLifecycleSnapshot = undefined,
    records: [16]Record = undefined,

    pub fn begin(self: *ClientInventory) bool {
        return self.ctx.programLifecycleBegin(&self.cursor) == abi.program_handle_ok;
    }
    pub fn next(self: *ClientInventory) ?Page {
        var page: abi.ProgramInventoryPageInfo = .{};
        if (self.ctx.programLifecyclePrograms(&self.cursor, &self.items, &page) != abi.program_handle_ok or
            page.snapshot_generation != self.cursor.snapshot_generation or page.returned > self.items.len or
            (page.status != abi.program_inventory_status_complete and page.status != abi.program_inventory_status_more)) return null;
        for (self.items[0..page.returned], 0..) |item, i| {
            self.records[i] = .{
                .owner = .{ .id = item.handle.instance_id, .generation = item.handle.generation },
                .running = item.state == program_instance_state_running,
            };
        }
        return .{ .records = self.records[0..page.returned], .complete = page.status == abi.program_inventory_status_complete };
    }
};

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
}

// Modeled native callbacks exercise the actual acquisition adapter. They do
// not claim native registry scheduling or kernel diagnostic execution.
const NativeProbe = struct {
    const Mode = enum { normal, begin_busy, page_busy, restart, epoch, bounds, invalid, empty_more, empty_complete, second_busy, second_restart, more_live };
    var mode: Mode = .normal;
    var table: abi.R4XStartR4Sys = .{};
    var raw: abi.R4XStartContext = .{};
    var bundle: r4os.program.Bundle = undefined;
    var life_begins: usize = 0;
    var life_reads: usize = 0;
    var diagnostic_begins: usize = 0;
    var diagnostic_reads: usize = 0;
    var pages: usize = 0;
    const Row = struct { id: u32, generation: u64, state: u8 };
    const rows = [_]Row{
        .{ .id = 7, .generation = 11, .state = 0 },
        .{ .id = 8, .generation = 99, .state = 0 },
        .{ .id = 9, .generation = 13, .state = 2 },
        .{ .id = 6, .generation = 17, .state = 0 },
        .{ .id = 10, .generation = 18, .state = 1 },
    };
    fn context(selected: Mode) r4os.r4sys.Context {
        mode = selected;
        table = .{};
        raw = .{};
        life_begins = 0;
        life_reads = 0;
        diagnostic_begins = 0;
        diagnostic_reads = 0;
        pages = 0;
        table.program_lifecycle_begin = @intFromPtr(&lifeBegin);
        table.program_lifecycle_programs = @intFromPtr(&lifePage);
        table.program_inventory_begin = @intFromPtr(&diagnosticBegin);
        table.program_inventory_programs = @intFromPtr(&diagnosticPage);
        bundle = .{ .raw = &raw, .sys = &table };
        return r4os.r4sys.Context.init(&bundle);
    }
    fn begin(cursor: *abi.ProgramInventoryCursor, lifecycle: bool) i32 {
        if (mode == .begin_busy) return abi.program_handle_error_would_block;
        cursor.* = .{ .snapshot_generation = 31, .program_epoch = 31, .flags = abi.program_inventory_cursor_flag_initialized | (if (lifecycle) abi.program_inventory_cursor_flag_lifecycle else @as(u32, 0)) };
        return abi.program_handle_ok;
    }
    fn lifeBegin(cursor: *abi.ProgramInventoryCursor) callconv(.c) i32 {
        life_begins += 1;
        return begin(cursor, true);
    }
    fn diagnosticBegin(cursor: *abi.ProgramInventoryCursor, summary: *abi.ProgramInventorySummary) callconv(.c) i32 {
        diagnostic_begins += 1;
        summary.* = .{};
        return begin(cursor, false);
    }
    fn page(cursor: *abi.ProgramInventoryCursor, capacity: u32, out: *abi.ProgramInventoryPageInfo, kind: u32) i32 {
        std.debug.assert(capacity == 16);
        pages += 1;
        if (mode == .page_busy or ((mode == .second_busy or mode == .more_live) and pages == 2)) return abi.program_handle_error_would_block;
        out.* = .{ .snapshot_generation = cursor.snapshot_generation, .kind = kind, .total = rows.len, .returned = rows.len, .status = abi.program_inventory_status_complete };
        switch (mode) {
            .restart => out.status = abi.program_inventory_status_restart,
            .second_restart => if (pages == 2) {
                out.status = abi.program_inventory_status_restart;
            },
            .epoch => out.snapshot_generation += 1,
            .bounds => out.returned = capacity + 1,
            .invalid => out.status = abi.program_inventory_status_invalid,
            .empty_more => {
                out.returned = 0;
                out.status = abi.program_inventory_status_more;
            },
            .empty_complete => out.returned = 0,
            else => {},
        }
        if ((mode == .second_busy or mode == .second_restart or mode == .more_live) and pages == 1) {
            out.returned = 1;
            out.status = abi.program_inventory_status_more;
        }
        if (out.returned > 0 and out.returned <= capacity) {
            cursor.program_after_generation = rows[out.returned - 1].generation;
            out.next_generation = cursor.program_after_generation;
        }
        out.has_more = @intFromBool(out.status == abi.program_inventory_status_more);
        return abi.program_handle_ok;
    }
    fn lifePage(cursor: *abi.ProgramInventoryCursor, out: [*]abi.ProgramLifecycleSnapshot, capacity: u32, header: *abi.ProgramInventoryPageInfo) callconv(.c) i32 {
        life_reads += 1;
        const rc = page(cursor, capacity, header, abi.program_inventory_kind_lifecycle);
        if (rc == abi.program_handle_ok) for (rows[0..@min(header.returned, rows.len)], 0..) |row, i| {
            out[i] = .{ .handle = .{ .instance_id = row.id, .generation = row.generation }, .state = row.state };
        };
        return rc;
    }
    fn diagnosticPage(cursor: *abi.ProgramInventoryCursor, out: [*]abi.ProgramInstanceSnapshot, capacity: u32, header: *abi.ProgramInventoryPageInfo) callconv(.c) i32 {
        diagnostic_reads += 1;
        const rc = page(cursor, capacity, header, abi.program_inventory_kind_program);
        if (rc == abi.program_handle_ok) for (rows[0..@min(header.returned, rows.len)], 0..) |row, i| {
            out[i] = .{ .handle = .{ .instance_id = row.id, .generation = row.generation }, .info = .{ .state = row.state } };
        };
        return rc;
    }
    fn expectLifecycleOnly(expected_reads: usize) !void {
        try std.testing.expectEqual(@as(usize, 0), diagnostic_begins);
        try std.testing.expectEqual(@as(usize, 0), diagnostic_reads);
        try std.testing.expectEqual(@as(usize, 1), life_begins);
        try std.testing.expectEqual(expected_reads, life_reads);
    }
};

test "actual native owner reader uses lifecycle identity generations and running state only" {
    const ctx = NativeProbe.context(.normal);
    var reader = ClientInventory{ .ctx = &ctx };
    const owners = [_]Owner{ .{ .id = 7, .generation = 11 }, .{ .id = 8, .generation = 12 }, .{ .id = 9, .generation = 13 }, .{ .id = 6, .generation = 0 }, .{ .id = 10, .generation = 18 } };
    var generations: [owners.len]u64 = undefined;
    try std.testing.expect(collectRunning(&owners, &generations, &reader));
    try std.testing.expectEqualSlices(u64, &.{ 11, 0, 0, 17, 0 }, &generations);
    try NativeProbe.expectLifecycleOnly(1);
}

test "actual native owner reader refuses busy restart changed epoch invalid bounds and incomplete absence" {
    for ([_]NativeProbe.Mode{ .begin_busy, .page_busy, .restart, .epoch, .bounds, .invalid, .empty_more, .second_busy, .second_restart }) |mode| {
        const ctx = NativeProbe.context(mode);
        var reader = ClientInventory{ .ctx = &ctx };
        const owners = [_]Owner{ .{ .id = 7, .generation = 11 }, .{ .id = 8, .generation = 12 } };
        var generations: [owners.len]u64 = undefined;
        try std.testing.expect(!collectRunning(&owners, &generations, &reader));
        try NativeProbe.expectLifecycleOnly(if (mode == .begin_busy) 0 else if (mode == .second_busy or mode == .second_restart) 2 else 1);
        if (mode == .second_busy or mode == .second_restart) try std.testing.expectEqual(@as(u64, 11), generations[0]);
    }
}

test "actual native owner reader keeps complete absence and shared positive more authority distinct" {
    for ([_]NativeProbe.Mode{ .empty_complete, .more_live }) |mode| {
        const ctx = NativeProbe.context(mode);
        var reader = ClientInventory{ .ctx = &ctx };
        const duplicates = [_]Owner{.{ .id = 7, .generation = 11 }} ** 16;
        var generations: [16]u64 = undefined;
        try std.testing.expect(collectRunning(&duplicates, &generations, &reader));
        for (generations) |generation| try std.testing.expectEqual(@as(u64, if (mode == .more_live) 11 else 0), generation);
        try NativeProbe.expectLifecycleOnly(1);
    }
}
