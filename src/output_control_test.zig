//! Exercise the real catalog consumer through its normal R4AUDIO facade.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const t = std.testing;
const Model = struct {
    var items: [2]a.AudioOutputInfo = undefined;
    var selections: usize = 0;
    var fail: bool = false;
    var count: usize = 2;
    var query_fail: bool = false;
    var queries: usize = 0;
    fn info(index: u32, out: *a.AudioOutputInfo) callconv(.c) i32 {
        queries += 1;
        if (query_fail) return a.service_api_result_busy;
        if (index >= count) return 0;
        out.* = items[index]; return 1;
    }
    fn select(id: *const [64]u8) callconv(.c) i32 {
        selections += 1;
        if (fail) return -1;
        for (&items) |*item| {
            item.flags &= ~a.audio_output_flag_active;
            if (std.mem.eql(u8, id, &item.id)) item.flags |= a.audio_output_flag_active;
        }
        return 0;
    }
};
pub fn check() !void {
    Model.items = .{ .{ .kind = a.audio_output_kind_line_out, .availability = a.audio_output_available },
        .{ .kind = a.audio_output_kind_hdmi, .availability = a.audio_output_waiting_for_eld } };
    @memcpy(Model.items[0].id[0..6], "analog");
    @memcpy(Model.items[1].id[0..4], "hdmi");
    @memcpy(Model.items[1].name[0..7], "Hisense"); // Model data, no physical receiver claim.
    Model.selections = 0; Model.fail = false;
    Model.count = 2; Model.query_fail = false; Model.queries = 0;
    var table: a.R4XStartR4Audio = .{};
    table.audio_output_info = @intFromPtr(&Model.info);
    table.audio_select_output = @intFromPtr(&Model.select);
    const raw: a.R4XStartContext = .{};
    const bundle: r4os.program.Bundle = .{ .raw = &raw, .audio = &table };
    const audio = r4os.r4audio.Context.init(&bundle);
    var state: @import("output_control.zig").State = .{};
    try t.expect(state.refresh(&audio, 0, 500, true));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expect(state.backendPresent());
    const queries = Model.queries;
    for (1..500) |now| {
        try t.expect(state.refresh(&audio, now, 500, false));
        try t.expect(state.backendPresent());
    }
    try t.expectEqual(queries, Model.queries);
    Model.items[1].availability = a.audio_output_available;
    try t.expect(state.refresh(&audio, 500, 500, false));
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expectEqual(@as(i32, 0), state.select(&audio, Model.items[1].id));
    const first_revision = state.revision;
    // HDA withdrew an active route when its display generation changed.
    Model.items[1].flags = 0;
    Model.items[1].availability = a.audio_output_waiting_for_eld;
    try t.expect(state.refresh(&audio, 1000, 500, false));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expectEqualDeep(Model.items[1].id, state.desired);
    try t.expect(state.revision > first_revision);
    Model.items[1].availability = a.audio_output_available;
    try t.expect(state.refresh(&audio, 1500, 500, false));
    try t.expectEqualDeep(Model.items[1].id, state.active);
    // A byte-identical catalog ID still needs reactivation after a new ELD
    // revision stopped the old HDA stream and cleared its active flag.
    const selections = Model.selections;
    Model.items[1].flags = 0;
    try t.expect(state.refresh(&audio, 2000, 500, false));
    try t.expectEqual(selections + 1, Model.selections);
    const page = state.page(0, 0x100000003, 0);
    try t.expect(page.count == 2 and page.service_epoch == 0x100000003 and page.revision == state.revision);
    try t.expectEqualDeep(Model.items[1].name, page.active_name);
    // An explicit analog preference survives HDMI reconnection.
    try t.expectEqual(@as(i32, 0), state.select(&audio, Model.items[0].id));
    try t.expect(state.refresh(&audio, 2500, 500, false));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    // A DP endpoint follows the same priority and preference rules, but its
    // published selection reason must identify the actual transport.
    Model.items[1].kind = a.audio_output_kind_display_port;
    try t.expect(state.refresh(&audio, 3000, 500, false));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expectEqual(@as(i32, 0), state.select(&audio, @splat(0)));
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expectEqual(a.audio_output_reason_auto_display_port, state.reason);

    // Failed enumeration must not turn the retained old active ID into a
    // current backend receipt, including within the existing poll deadline.
    const revision = state.revision;
    Model.query_fail = true;
    try t.expect(!state.refresh(&audio, 3500, 500, false));
    try t.expect(!state.backendPresent());
    try t.expect(state.revision > revision);
    try t.expect(state.refresh(&audio, 3501, 500, false));
    try t.expect(!state.backendPresent());
    Model.query_fail = false;
    try t.expect(state.refresh(&audio, 4000, 500, false));
    try t.expect(state.backendPresent());

    // A terminal backend withdrawal empties the authoritative catalog. A
    // later provider with the same persistent IDs needs a new publication.
    Model.count = 0;
    try t.expect(state.refresh(&audio, 4500, 500, false));
    try t.expect(!state.backendPresent());
    try t.expectEqual(@as(usize, 0), state.count);
    const empty_revision = state.revision;
    Model.count = 2;
    try t.expect(state.refresh(&audio, 5000, 500, false));
    try t.expect(state.backendPresent());
    try t.expect(state.revision > empty_revision);

    // A stream's real NoEndpoint invalidates the cache before its deadline.
    state.invalidate();
    try t.expect(!state.backendPresent());
    try t.expectEqual(@as(u8, 0), state.active[0]);
    Model.query_fail = true;
    try t.expect(!state.refresh(&audio, 5001, 500, false));
    try t.expect(!state.backendPresent());
    Model.query_fail = false;
    try t.expect(state.refresh(&audio, 5501, 500, false));
    try t.expect(state.backendPresent());
}
