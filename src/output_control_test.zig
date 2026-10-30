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
    var registration: u64 = 0x1_0000_0055;
    var generation: u64 = 0x2_0000_0055;
    var registry: u64 = 7;
    var invalid_metadata = false;
    var select_result: i32 = 0;
    fn info(index: u32, out: *a.AudioOutputInfo) callconv(.c) i32 {
        queries += 1;
        if (query_fail) return a.service_api_result_busy;
        if (index >= count) return 0;
        out.* = items[index];
        return 1;
    }
    fn catalog(outputs: [*]a.AudioOutputInfo, capacity: u32, out: *a.AudioOutputCatalog) callconv(.c) i32 {
        queries += 1;
        std.debug.assert(capacity >= 256);
        // A failed capture may already have overwritten caller scratch.
        if (query_fail) {
            outputs[0] = .{};
            return a.service_api_result_busy;
        }
        @memcpy(outputs[0..count], items[0..count]);
        out.* = .{ .registry_generation = registry, .count = @intCast(count), .provider_count = 1 };
        out.providers[0] = .{ .registration = registration, .generation = generation, .count = if (invalid_metadata) 33 else @intCast(count), .active_index = -1 };
        return 1;
    }
    fn select(id: *const [64]u8) callconv(.c) i32 {
        selections += 1;
        if (fail) return -1;
        if (select_result != 0) return select_result;
        for (&items) |*item| {
            item.flags &= ~a.audio_output_flag_active;
            if (std.mem.eql(u8, id, &item.id)) item.flags |= a.audio_output_flag_active;
        }
        return 0;
    }
};

// Complete the real operation synchronously only in this controlled owner
// adapter. Production dispatch never executes it; native tests cover Join.
fn refresh(state: *@import("output_control.zig").State, audio: *const r4os.r4audio.Context, now: u64, interval: u64, force: bool) bool {
    const due = force or now >= state.next_poll;
    if (!state.refresh(audio, now, interval, force)) return false;
    if (due) {
        const operation = state.prepare(state.desired, false) catch return false;
        state.complete(&operation, operation.execute(audio));
    }
    return true;
}
fn select(state: *@import("output_control.zig").State, audio: *const r4os.r4audio.Context, id: [64]u8) i32 {
    const operation = state.prepare(id, true) catch |err| return if (err == error.NoEndpoint) a.service_api_result_no_endpoint else a.service_api_result_invalid;
    const outcome = operation.execute(audio);
    state.complete(&operation, outcome);
    return outcome.result;
}

pub fn check() !void {
    Model.items = .{ .{ .kind = a.audio_output_kind_line_out, .availability = a.audio_output_available }, .{ .kind = a.audio_output_kind_hdmi, .availability = a.audio_output_waiting_for_eld } };
    @memcpy(Model.items[0].id[0..6], "analog");
    @memcpy(Model.items[1].id[0..4], "hdmi");
    @memcpy(Model.items[1].name[0..7], "Hisense"); // Model data, no physical receiver claim.
    Model.selections = 0;
    Model.fail = false;
    Model.count = 2;
    Model.query_fail = false;
    Model.queries = 0;
    Model.registration = 0x1_0000_0055;
    Model.generation = 0x2_0000_0055;
    Model.registry = 7;
    Model.invalid_metadata = false;
    var table: a.R4XStartR4Audio = .{};
    table.audio_output_info = @intFromPtr(&Model.info);
    table.audio_output_catalog = @intFromPtr(&Model.catalog);
    table.audio_select_output = @intFromPtr(&Model.select);
    const raw: a.R4XStartContext = .{};
    const bundle: r4os.program.Bundle = .{ .raw = &raw, .audio = &table };
    const audio = r4os.r4audio.Context.init(&bundle);
    var state: @import("output_control.zig").State = .{};
    try t.expect(refresh(&state, &audio, 0, 500, true));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expect(state.backendPresent());
    const queries = Model.queries;
    for (1..500) |now| {
        try t.expect(refresh(&state, &audio, now, 500, false));
        try t.expect(state.backendPresent());
    }
    try t.expectEqual(queries, Model.queries);
    Model.items[1].availability = a.audio_output_available;
    try t.expect(refresh(&state, &audio, 500, 500, false));
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expectEqual(@as(i32, 0), select(&state, &audio, Model.items[1].id));
    const first_revision = state.revision;
    // HDA withdrew an active route when its display generation changed.
    Model.items[1].flags = 0;
    Model.items[1].availability = a.audio_output_waiting_for_eld;
    try t.expect(refresh(&state, &audio, 1000, 500, false));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expectEqualDeep(Model.items[1].id, state.desired);
    try t.expect(state.revision > first_revision);
    Model.items[1].availability = a.audio_output_available;
    try t.expect(refresh(&state, &audio, 1500, 500, false));
    try t.expectEqualDeep(Model.items[1].id, state.active);
    // A byte-identical catalog ID still needs reactivation after a new ELD
    // revision stopped the old HDA stream and cleared its active flag.
    const selections = Model.selections;
    Model.items[1].flags = 0;
    try t.expect(refresh(&state, &audio, 2000, 500, false));
    try t.expectEqual(selections + 1, Model.selections);
    const page = state.page(0, 0x100000003, 0);
    try t.expect(page.count == 2 and page.service_epoch == 0x100000003 and page.revision == state.revision);
    try t.expectEqualDeep(Model.items[1].name, page.active_name);
    // An explicit analog preference survives HDMI reconnection.
    try t.expectEqual(@as(i32, 0), select(&state, &audio, Model.items[0].id));
    try t.expect(refresh(&state, &audio, 2500, 500, false));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    // A DP endpoint follows the same priority and preference rules, but its
    // published selection reason must identify the actual transport.
    Model.items[1].kind = a.audio_output_kind_display_port;
    try t.expect(refresh(&state, &audio, 3000, 500, false));
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expectEqual(@as(i32, 0), select(&state, &audio, @splat(0)));
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expectEqual(a.audio_output_reason_auto_display_port, state.reason);

    // Failed enumeration must not turn the retained old active ID into a
    // current backend receipt, including within the existing poll deadline.
    const revision = state.revision;
    Model.query_fail = true;
    try t.expect(!refresh(&state, &audio, 3500, 500, false));
    try t.expect(!state.backendPresent());
    try t.expect(state.revision > revision);
    try t.expect(refresh(&state, &audio, 3501, 500, false));
    try t.expect(!state.backendPresent());
    Model.query_fail = false;
    try t.expect(refresh(&state, &audio, 4000, 500, false));
    try t.expect(state.backendPresent());

    // A terminal backend withdrawal empties the authoritative catalog. A
    // later provider with the same persistent IDs needs a new publication.
    Model.count = 0;
    try t.expect(refresh(&state, &audio, 4500, 500, false));
    try t.expect(!state.backendPresent());
    try t.expectEqual(@as(usize, 0), state.count);
    const empty_revision = state.revision;
    Model.count = 2;
    try t.expect(refresh(&state, &audio, 5000, 500, false));
    try t.expect(state.backendPresent());
    try t.expect(state.revision > empty_revision);

    // A stream's real NoEndpoint invalidates the cache before its deadline.
    state.invalidate();
    try t.expect(!state.backendPresent());
    try t.expectEqual(@as(u8, 0), state.active[0]);
    Model.query_fail = true;
    try t.expect(!refresh(&state, &audio, 5001, 500, false));
    try t.expect(!state.backendPresent());
    Model.query_fail = false;
    try t.expect(refresh(&state, &audio, 5501, 500, false));
    try t.expect(state.backendPresent());

    // Identical rows under a new actual registration/provider epoch still
    // require a new service publication identity. Never truncate u64 epochs.
    const old_revision = state.revision;
    Model.registration += 1;
    Model.registry += 1;
    try t.expect(refresh(&state, &audio, 6001, 500, false));
    try t.expect(state.revision > old_revision);
    const provider_revision = state.revision;
    Model.generation += 1;
    try t.expect(refresh(&state, &audio, 6501, 500, false));
    try t.expect(state.revision > provider_revision);
    try t.expectEqual(Model.registration, state.catalog_epoch.providers[0].registration);
    try t.expectEqual(Model.generation, state.catalog_epoch.providers[0].generation);
    const retained = state.catalog;
    const retained_epoch = state.catalog_epoch;
    Model.invalid_metadata = true;
    try t.expect(!refresh(&state, &audio, 7001, 500, false));
    try t.expect(!state.backendPresent());
    try t.expectEqualDeep(retained, state.catalog);
    try t.expectEqualDeep(retained_epoch, state.catalog_epoch);
    Model.invalid_metadata = false;
    Model.items[1].id = Model.items[0].id;
    try t.expect(!refresh(&state, &audio, 7501, 500, false));
    try t.expectEqualDeep(retained, state.catalog);
    table.audio_output_catalog = 0;
    try t.expect(!refresh(&state, &audio, 8001, 500, false));
    try t.expectEqual(a.audio_output_reason_api_unavailable, state.reason);
    try t.expect(!state.backendPresent());
    try selectionLifecycle(&audio, &raw);
}

const JoinFixture = struct {
    var entry: a.ThreadEntryFn = undefined;
    var argument: u64 = 0;
    var expected: a.ProgramJoinHandle = .{};
    var generation: u64 = 0x1_0000_0056;
    var result: i32 = a.thread_error_timeout;
    var ran = false;
    var creates: usize = 0;
    var joins: usize = 0;
    fn create(callback: a.ThreadEntryFn, arg: u64, _: u64, _: u32, out: *a.ProgramJoinHandle) callconv(.c) i32 {
        entry = callback;
        argument = arg;
        ran = false;
        creates += 1;
        generation += 1;
        expected = .{ .thread_id = 17, .instance_id = 9, .thread_generation = generation, .instance_generation = 0x2_0000_0056 };
        out.* = expected;
        return a.thread_ok;
    }
    fn join(handle: *const a.ProgramJoinHandle, _: u64, exit: *i32) callconv(.c) i32 {
        joins += 1;
        if (!std.mem.eql(u8, std.mem.asBytes(handle), std.mem.asBytes(&expected))) return a.thread_error_invalid;
        if (result == a.thread_ok) {
            if (ran) return a.thread_error_invalid;
            exit.* = entry(argument);
            ran = true;
        }
        return result;
    }
};

fn selectionLifecycle(audio: *const r4os.r4audio.Context, raw: *const a.R4XStartContext) !void {
    const control = @import("output_control.zig");
    const selection = @import("output_selection.zig");
    Model.items = .{ .{ .availability = a.audio_output_available, .kind = a.audio_output_kind_line_out, .flags = a.audio_output_flag_active }, .{ .availability = a.audio_output_available, .kind = a.audio_output_kind_hdmi } };
    @memcpy(Model.items[0].id[0..6], "analog");
    @memcpy(Model.items[1].id[0..4], "hdmi");
    Model.fail = false;
    Model.select_result = 0;
    Model.selections = 0;
    var state: control.State = .{ .count = 2, .active = Model.items[0].id, .reason = a.audio_output_reason_auto_analog };
    @memcpy(state.catalog[0..2], &Model.items);
    var operation = try state.prepare(Model.items[1].id, true);
    try t.expectEqual(@as(usize, 0), Model.selections);
    try t.expectEqual(@as(usize, 1), operation.count);
    var sys_table: a.R4XStartR4Sys = .{};
    sys_table.thread_create_handle = @intFromPtr(&JoinFixture.create);
    sys_table.thread_handle_join = @intFromPtr(&JoinFixture.join);
    const bundle: r4os.program.Bundle = .{ .raw = raw, .sys = &sys_table };
    const sys = r4os.r4sys.Context.init(&bundle);
    var job: selection.Job = .{};
    const request: selection.Request = .{ .client_id = 27, .client_generation = 0x3_0000_0056, .request_id = 28, .started = 31 };
    const epoch: u64 = 0x4_0000_0056;
    JoinFixture.result = a.thread_error_timeout;
    JoinFixture.creates = 0;
    JoinFixture.joins = 0;
    try t.expectEqual(@as(i32, 0), job.start(&sys, audio.*, epoch, operation, request));
    const handle = job.handle;
    state.transition();
    // Original caller/dispatcher storage can change; the worker has its own
    // target and exactly bound request, and a second intent cannot replace it.
    operation.targets[0].id = Model.items[0].id;
    try t.expectEqual(a.service_api_result_busy, job.start(&sys, audio.*, epoch + 1, operation, null));
    try t.expectEqualDeep(handle, job.handle);
    for (0..3) |_| try t.expect(job.poll(&sys, 0) == .pending);
    try t.expect(!state.backendPresent());
    try t.expectEqualDeep(Model.items[0].id, state.page(0, epoch, 0).active_id);
    try t.expectEqualDeep(@as([64]u8, @splat(0)), state.desired);
    try t.expectEqual(@as(usize, 0), Model.selections);
    JoinFixture.result = a.thread_error_invalid;
    const fault = job.poll(&sys, 0);
    try t.expect(fault == .fault and fault.fault == a.thread_error_invalid and job.in_flight);
    try t.expectEqualDeep(handle, job.handle);
    JoinFixture.result = a.thread_ok;
    const completed = switch (job.poll(&sys, 0)) {
        .completed => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try t.expectEqual(epoch, completed.service_epoch);
    try t.expectEqualDeep(request, completed.request.?);
    try t.expectEqual(@as(usize, 1), JoinFixture.creates);
    try t.expectEqual(@as(usize, 1), Model.selections);
    try t.expectEqual(@as(i32, 0), completed.outcome.result);
    try t.expect(!job.in_flight and job.handle.thread_id == 0);
    // Join alone does not publish a service preference; the dispatcher does.
    try t.expectEqualDeep(@as([64]u8, @splat(0)), state.desired);
    state.complete(&completed.operation, completed.outcome);
    try t.expectEqualDeep(Model.items[1].id, state.desired);
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expect(state.backendPresent());
    const joins = JoinFixture.joins;
    try t.expect(job.poll(&sys, 0) == .idle);
    try t.expectEqual(joins, JoinFixture.joins);
    // An actual failed replacement preserves the old available route and
    // preference. Busy must not try the next copied candidate or replay.
    operation = try state.prepare(Model.items[0].id, true);
    Model.fail = true;
    const failed = operation.execute(audio);
    state.complete(&operation, failed);
    try t.expectEqual(@as(i32, -1), failed.result);
    try t.expectEqualDeep(Model.items[1].id, state.desired);
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expectEqual(a.audio_output_reason_activation_failed, state.reason);
    Model.fail = false;
    Model.select_result = a.service_api_result_busy;
    Model.selections = 0;
    operation.count = 2;
    operation.fallback = .{ .reason = .activation_failed };
    operation.targets[1] = .{ .id = Model.items[1].id, .index = 1, .reason = .preferred };
    try t.expectEqual(a.service_api_result_busy, operation.execute(audio).result);
    try t.expectEqual(@as(usize, 1), Model.selections);
    Model.select_result = 0;
    // A real catalog can withdraw the selected route before the dispatcher
    // observes a successful provider ACK. Reconcile only the fresh display.
    state.count = 0;
    state.reconcile();
    try t.expectEqualDeep(Model.items[1].id, state.desired);
    try t.expectEqual(@as(u8, 0), state.active[0]);
    try t.expectEqual(a.audio_output_reason_none_available, state.reason);
    try t.expect(!state.backendPresent());
    Model.selections = 0;
    state.count = 2;
    @memcpy(state.catalog[0..2], &Model.items);
    state.catalog[0].flags = a.audio_output_flag_active;
    state.catalog[1].flags = 0;
    state.active = Model.items[0].id;
    state.reconcile();
    try t.expectEqual(a.audio_output_reason_catalog_busy, state.reason);
    try t.expectEqualDeep(Model.items[0].id, state.active);
    try t.expectEqual(@as(usize, 0), Model.selections);
    // Reordering/DP publication uses the new row index, not the completed
    // operation's old slot, without another driver select.
    state.desired = @splat(0);
    state.catalog[0] = Model.items[1];
    state.catalog[0].flags = a.audio_output_flag_active;
    state.catalog[0].kind = a.audio_output_kind_display_port;
    state.catalog[1] = Model.items[0];
    state.catalog[1].flags = 0;
    state.reconcile();
    try t.expectEqualDeep(Model.items[1].id, state.active);
    try t.expectEqual(a.audio_output_reason_auto_display_port, state.reason);
    try t.expectEqual(@as(usize, 0), Model.selections);
}
