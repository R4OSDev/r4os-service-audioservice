const std = @import("std");
const r4os = @import("r4os");
const master_control = @import("master_control.zig");
const session_ownership = @import("session_ownership.zig");

const service_name = "AUDSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const default_volume: u32 = master_control.default_volume;
const max_sessions: usize = @intCast(r4os.abi.audio_service_max_sessions);
const session_reap_ms: u64 = 200;
const persist_debounce_ms: u64 = 500;
const persist_poll_ms: u64 = 100;
const persist_retry_ms: u64 = 2000;
const persist_selftest_wait_ms: u64 = 15_000;
const master_config_path: [*:0]const u8 = "C:\\R4OS\\CONFIG\\AUDIO.R4S";
const master_config_stage_path: [*:0]const u8 = "C:\\R4OS\\CONFIG\\AUDIO.TMP";
const master_config_backup_path: [*:0]const u8 = "C:\\R4OS\\CONFIG\\AUDIO.BAK";
const program_instance_state_running: u8 = 0;

// Non-zero initializer keeps the R4X scratch buffer file-backed instead of BSS-only.
var service_payload_buffer: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var service_status_reply: r4os.abi.AudioServiceStatus = .{};
var service_result_reply: r4os.abi.AudioServiceStreamResult = .{};
var service_master_reply: r4os.abi.AudioServiceMasterState = .{};

const App = struct {
    sys: r4os.r4sys.Context,
    audio: r4os.r4audio.Context,
    devices: r4os.Devices,
    instance_id: u64,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .audio = r4_app.audioLowLevel() orelse return null,
            .devices = r4_app.devices() orelse return null,
            .instance_id = r4_app.raw.instance_id,
        };
    }
};

const Session = struct {
    open: bool = false,
    client_id: u32 = 0,
    client_generation: u64 = 0,
    stream_id: u32 = 0,
    backend_stream_id: u32 = 0,
    rate: u32 = 0,
    channels: u16 = 0,
    format: u16 = 0,
    fixed_volume: u32 = default_volume,
    writes: u64 = 0,
    bytes_written: u64 = 0,
};

const PersistenceJob = struct {
    in_flight: bool = false,
    sys: r4os.r4sys.Context = undefined,
    thread_handle: r4os.abi.ProgramJoinHandle = .{},
    target_generation: u64 = 0,
    target_due_tick: u64 = 0,
    target_selected_volume_fixed: u32 = default_volume,
    target_last_audible_volume_fixed: u32 = default_volume,
    target_muted: u32 = 0,
    completed_snapshot: master_control.Persisted = .{},
};

const AudioServiceState = struct {
    sessions: [max_sessions]Session = .{Session{}} ** max_sessions,
    next_stream_id: u32 = 1,
    revision: u32 = 1,
    master: master_control.State = .{},
    service_epoch: u64 = 0,
    config_loaded: bool = false,
    config_defaulted: bool = false,
    config_error: bool = false,
    persist_pending: bool = false,
    persist_due_tick: u64 = 0,
    last_persisted: master_control.Persisted = .{},
    persistence: PersistenceJob = .{},
    persist_writes: u64 = 0,
    persist_failures: u64 = 0,
    config_loads: u64 = 0,
    master_changes: u64 = 0,
    requests: u64 = 0,
    status_requests: u64 = 0,
    stream_open_requests: u64 = 0,
    stream_write_requests: u64 = 0,
    stream_close_requests: u64 = 0,
    set_volume_requests: u64 = 0,
    master_volume_changes: u64 = 0,
    bad_ops: u64 = 0,
    bytes_written: u64 = 0,
    backend_ok: u64 = 0,
    backend_fail: u64 = 0,
    request_total_ticks: u64 = 0,
    request_max_ticks: u64 = 0,
    request_last_ticks: u64 = 0,
    write_request_total_ticks: u64 = 0,
    write_request_max_ticks: u64 = 0,
    write_request_last_ticks: u64 = 0,
    last_write_bytes: u32 = 0,
    lazy_open_count: u32 = 0,
    silence_write_count: u64 = 0,
    silence_bytes: u64 = 0,
    idle_close_count: u64 = 0,
    peak_sessions: u32 = 0,
    backend_present: bool = false,
    last_error: [r4os.abi.audio_service_error_bytes]u8 = .{0} ** r4os.abi.audio_service_error_bytes,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    var app = App.init(r4_app) orelse return r4os.abi.err_no_group;
    if (hasArg(app.sys.argsRaw(), selftest_arg)) return runSelfTest(&app);
    if (hasArg(app.sys.argsRaw(), ping_arg)) return runPing(&app);
    return runService(&app);
}

fn runService(app: *const App) i32 {
    if (!app.sys.hasFn("service_call")) return r4os.abi.service_api_result_invalid;

    var info: r4os.abi.ServiceInfo = .{};
    var handle: u32 = 0;
    var waited: u32 = 0;
    while (waited < 100 and handle == 0) : (waited += 1) {
        const rc = app.sys.serviceEndpointRegister(service_name, 0, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            handle = info.handle;
            app.sys.write("AUDSVC endpoint handle=");
            app.sys.printU64(@intCast(handle));
            app.sys.println("");
            break;
        }
        app.sys.sleepTicks(1);
    }
    if (handle == 0) {
        app.sys.println("AUDSVC endpoint registration failed");
        return r4os.abi.service_api_result_no_endpoint;
    }

    var state = AudioServiceState{ .service_epoch = app.instance_id };
    copyFixed(state.last_error[0..], "ready");
    loadMasterConfiguration(app, &state);
    refreshBackendState(app, &state);

    var service_loop = r4os.ServiceLoop.init(app.sys, handle, .{});
    const reap_interval = @max(app.sys.ticksFromMilliseconds(session_reap_ms), 1);
    var next_reap_tick = app.sys.ticks() +| reap_interval;
    while (true) {
        const now = app.sys.ticks();
        serviceMasterPersistence(app, &state);
        if (openSessionCount(&state) > 0 and now >= next_reap_tick) {
            reapDisconnectedSessions(app, &state);
            refreshBackendState(app, &state);
            next_reap_tick = app.sys.ticks() +| reap_interval;
        }
        var deadline: ?u64 = if (openSessionCount(&state) > 0) next_reap_tick else null;
        if (state.persist_pending and !state.persistence.in_flight and
            (deadline == null or state.persist_due_tick < deadline.?))
        {
            deadline = state.persist_due_tick;
        }
        if (state.persistence.in_flight) {
            const poll_tick = app.sys.ticks() +| @max(app.sys.ticksFromMilliseconds(persist_poll_ms), 1);
            if (deadline == null or poll_tick < deadline.?) deadline = poll_tick;
        }
        switch (service_loop.wait(deadline)) {
            .requests => |pending| {
                const rc = service_loop.drain(pending, handleRequest, .{ app, handle, &state });
                if (rc >= 0 or rc == r4os.abi.service_api_result_not_found) continue;
                flushMasterPersistence(app, &state);
                closeOpenSessions(app, &state);
                _ = app.sys.serviceEndpointUnregister(handle);
                return rc;
            },
            .idle, .deadline => {},
            .stop => break,
            .failure => |raw| {
                flushMasterPersistence(app, &state);
                closeOpenSessions(app, &state);
                _ = app.sys.serviceEndpointUnregister(handle);
                return raw;
            },
        }
    }

    service_loop.report(service_name);
    flushMasterPersistence(app, &state);
    closeOpenSessions(app, &state);
    _ = app.sys.serviceEndpointUnregister(handle);
    app.sys.println("AUDSVC stopped cleanly");
    return 0;
}

fn handleRequest(app: *const App, handle: u32, state: *AudioServiceState) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    const got = app.sys.serviceEndpointRecv(handle, &header, service_payload_buffer[0..]);
    if (got < 0) return got;
    if (got == 0 and header.magic != r4os.abi.service_api_magic) return 0;

    state.requests +%= 1;
    const payload_len: usize = @intCast(got);
    const payload = service_payload_buffer[0..payload_len];
    const request_start = app.sys.ticks();
    const rc = switch (header.op) {
        r4os.abi.audio_service_op_status => replyStatus(app, handle, header.request_id, state, request_start),
        r4os.abi.audio_service_op_set_master_volume => handleSetMasterVolume(app, handle, header.request_id, state, payload, request_start),
        r4os.abi.audio_service_op_master_status => replyMasterState(app, handle, header.request_id, state, request_start),
        r4os.abi.audio_service_op_set_master_state => handleSetMasterState(app, handle, header.request_id, state, payload, request_start),
        r4os.abi.audio_service_op_open_stream => handleOpenStream(app, handle, header.request_id, header.client_id, state, payload, request_start),
        r4os.abi.audio_service_op_write_stream => handleWriteStream(app, handle, header.request_id, header.client_id, state, payload, request_start),
        r4os.abi.audio_service_op_close_stream => handleCloseStream(app, handle, header.request_id, header.client_id, state, payload, request_start),
        r4os.abi.audio_service_op_set_stream_volume => handleSetStreamVolume(app, handle, header.request_id, header.client_id, state, payload, request_start),
        else => {
            state.bad_ops +%= 1;
            copyFixed(state.last_error[0..], "bad-op");
            recordRequestTicks(app, state, header.op, request_start);
            return app.sys.serviceEndpointReply(handle, header.request_id, r4os.abi.service_api_result_bad_op, "BADOP");
        },
    };
    return rc;
}

fn handleSetMasterVolume(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceVolumeRequest = .{};
    if (!parseVolumeRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-volume");
        recordRequestTicks(app, state, r4os.abi.audio_service_op_set_master_volume, request_start);
        return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_invalid, "");
    }

    if (master_control.applyLegacyVolume(&state.master, request.fixed_volume)) {
        state.master_volume_changes +%= 1;
        state.master_changes +%= 1;
        copyFixed(state.last_error[0..], "master-volume");
        bumpRevision(state);
        scheduleMasterPersistence(app, state);
        applyMasterToStreams(app, state);
    }

    return replyStatus(app, handle, request_id, state, request_start);
}

fn handleSetMasterState(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceMasterRequest = .{};
    if (!parseMasterRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-master-state");
        recordRequestTicks(app, state, r4os.abi.audio_service_op_set_master_state, request_start);
        return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_invalid, "");
    }
    if (request.expected_revision != 0 and request.expected_revision != state.master.revision) {
        copyFixed(state.last_error[0..], "master-stale");
        recordRequestTicks(app, state, r4os.abi.audio_service_op_set_master_state, request_start);
        return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_busy, "");
    }

    const changed = master_control.applyExplicit(&state.master, .{
        .set_volume = (request.flags & r4os.abi.audio_master_request_flag_set_volume) != 0,
        .fixed_volume = request.fixed_volume,
        .set_muted = (request.flags & r4os.abi.audio_master_request_flag_set_muted) != 0,
        .muted = (request.flags & r4os.abi.audio_master_request_flag_muted) != 0,
    });
    if (changed) {
        state.master_volume_changes +%= 1;
        state.master_changes +%= 1;
        copyFixed(state.last_error[0..], if (state.master.muted) "master-muted" else "master-state");
        bumpRevision(state);
        scheduleMasterPersistence(app, state);
        applyMasterToStreams(app, state);
    }
    return replyMasterState(app, handle, request_id, state, request_start);
}

fn handleOpenStream(app: *const App, handle: u32, request_id: u32, client_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamOpenRequest = .{};
    state.stream_open_requests +%= 1;
    if (client_id == 0) {
        copyFixed(state.last_error[0..], "bad-client");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    if (!parseOpenRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-open");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    if (request.format != @intFromEnum(r4os.abi.AudioFormat.s16le)) {
        copyFixed(state.last_error[0..], "bad-format");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, -1, 0, 0, request_start);
    }
    const slot = freeSession(state) orelse {
        copyFixed(state.last_error[0..], "full");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, r4os.abi.service_api_result_full, 0, 0, request_start);
    };

    var reader = ClientInventory{ .ctx = &app.sys };
    var generation: [1]u64 = undefined;
    if (!session_ownership.collectRunning(&.{.{ .id = client_id, .generation = 0 }}, &generation, &reader) or generation[0] == 0) {
        copyFixed(state.last_error[0..], "client-snapshot-busy");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, r4os.abi.service_api_result_busy, 0, 0, request_start);
    }

    const stream_id = allocateStreamId(state) orelse {
        copyFixed(state.last_error[0..], "id-full");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, r4os.abi.service_api_result_full, 0, 0, request_start);
    };
    state.sessions[slot] = .{
        .open = true,
        .client_id = client_id,
        .client_generation = generation[0],
        .stream_id = stream_id,
        .rate = request.rate,
        .channels = request.channels,
        .format = request.format,
        .fixed_volume = request.fixed_volume,
    };
    updatePeak(state);
    copyFixed(state.last_error[0..], "stream-lazy");
    bumpRevision(state);
    const reply = replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, @intCast(stream_id), stream_id, 0, request_start);
    if (reply < 0) {
        state.sessions[slot] = .{};
        copyFixed(state.last_error[0..], "open-abandoned");
        bumpRevision(state);
    }
    return reply;
}

fn handleWriteStream(app: *const App, handle: u32, request_id: u32, client_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamWriteRequest = .{};
    state.stream_write_requests +%= 1;
    const header_size = @sizeOf(r4os.abi.AudioServiceStreamWriteRequest);
    if (payload.len < header_size or !parseWriteRequest(payload[0..header_size], &request)) {
        var detail: [48]u8 = undefined;
        const message = std.fmt.bufPrint(&detail, "bad-write {d}/{x}/{d}", .{ payload.len, request.magic, request.version }) catch "bad-write";
        copyFixed(state.last_error[0..], message);
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    if (request.byte_count > payload.len - header_size) {
        copyFixed(state.last_error[0..], "short-write");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, r4os.abi.service_api_result_invalid, request.stream_id, 0, request_start);
    }
    const data = payload[header_size .. header_size + @as(usize, @intCast(request.byte_count))];
    const session = sessionByStream(state, client_id, request.stream_id) orelse {
        copyFixed(state.last_error[0..], "bad-stream");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, -1, request.stream_id, 0, request_start);
    };

    if (session_ownership.isSilence(data)) {
        state.silence_write_count +%= 1;
        state.silence_bytes +%= @as(u64, @intCast(data.len));
        state.last_write_bytes = 0;
        if (session.backend_stream_id != 0) {
            const idle_close = app.audio.audioClose(session.backend_stream_id);
            if (idle_close >= 0) {
                session.backend_stream_id = 0;
                state.idle_close_count +%= 1;
                state.backend_ok +%= 1;
                bumpRevision(state);
                copyFixed(state.last_error[0..], "stream-idle");
            } else {
                state.backend_fail +%= 1;
                copyFixed(state.last_error[0..], "idle-close-failed");
            }
        } else {
            copyFixed(state.last_error[0..], "silence-suppressed");
        }
        session.writes +%= 1;
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, @intCast(data.len), request.stream_id, @intCast(data.len), request_start);
    }

    const materialize = materializeSession(app, state, session);
    if (materialize < 0) {
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, materialize, request.stream_id, 0, request_start);
    }

    const written = app.audio.audioWrite(session.backend_stream_id, data);
    if (written < 0) {
        if (written == r4os.abi.service_api_result_busy) {
            copyFixed(state.last_error[0..], "write-busy");
        } else {
            state.backend_fail +%= 1;
            copyFixed(state.last_error[0..], "write-failed");
        }
        if (written == r4os.abi.service_api_result_no_endpoint) state.backend_present = false;
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, written, request.stream_id, 0, request_start);
    }

    const bytes: u32 = @intCast(written);
    session.writes +%= 1;
    session.bytes_written +%= @as(u64, bytes);
    state.bytes_written +%= @as(u64, bytes);
    state.last_write_bytes = bytes;
    state.backend_ok +%= 1;
    copyFixed(state.last_error[0..], "stream-write");
    return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, written, request.stream_id, bytes, request_start);
}

fn handleCloseStream(app: *const App, handle: u32, request_id: u32, client_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamControlRequest = .{};
    state.stream_close_requests +%= 1;
    if (!parseControlRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-close");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_close_stream, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    const slot = sessionSlotByStream(state, client_id, request.stream_id) orelse {
        copyFixed(state.last_error[0..], "bad-stream");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_close_stream, -1, request.stream_id, 0, request_start);
    };

    const backend_stream_id = state.sessions[slot].backend_stream_id;
    const rc = if (backend_stream_id == 0) 0 else app.audio.audioClose(backend_stream_id);
    if (rc >= 0) {
        state.sessions[slot] = .{};
        state.backend_ok +%= 1;
        copyFixed(state.last_error[0..], "stream-close");
        bumpRevision(state);
    } else {
        state.backend_fail +%= 1;
        copyFixed(state.last_error[0..], "close-failed");
    }
    return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_close_stream, rc, request.stream_id, 0, request_start);
}

fn handleSetStreamVolume(app: *const App, handle: u32, request_id: u32, client_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamControlRequest = .{};
    state.set_volume_requests +%= 1;
    if (!parseControlRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-volume");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_set_stream_volume, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    const session = sessionByStream(state, client_id, request.stream_id) orelse {
        copyFixed(state.last_error[0..], "bad-stream");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_set_stream_volume, -1, request.stream_id, 0, request_start);
    };
    session.fixed_volume = request.fixed_volume;
    const rc = if (session.backend_stream_id == 0) 0 else app.audio.audioSetVolume(session.backend_stream_id, effectiveVolume(state, request.fixed_volume));
    if (rc >= 0) {
        state.backend_ok +%= 1;
        copyFixed(state.last_error[0..], "stream-volume");
        bumpRevision(state);
    } else {
        state.backend_fail +%= 1;
        copyFixed(state.last_error[0..], "volume-failed");
    }
    return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_set_stream_volume, rc, request.stream_id, 0, request_start);
}

fn replyStatus(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, request_start: u64) i32 {
    serviceMasterPersistence(app, state);
    state.status_requests +%= 1;
    refreshBackendState(app, state);
    recordRequestTicks(app, state, r4os.abi.audio_service_op_status, request_start);
    service_status_reply = makeStatus(state);
    const bytes: [*]const u8 = @ptrCast(&service_status_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.AudioServiceStatus)]);
}

fn replyMasterState(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, request_start: u64) i32 {
    serviceMasterPersistence(app, state);
    refreshBackendState(app, state);
    recordRequestTicks(app, state, r4os.abi.audio_service_op_master_status, request_start);
    service_master_reply = makeMasterState(state);
    const bytes: [*]const u8 = @ptrCast(&service_master_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.AudioServiceMasterState)]);
}

fn replyResult(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, action: u16, result: i32, stream_id: u32, bytes: u32, request_start: u64) i32 {
    recordRequestTicks(app, state, action, request_start);
    service_result_reply = r4os.abi.AudioServiceStreamResult{
        .action = action,
        .result = result,
        .stream_id = stream_id,
        .bytes = bytes,
        .flags = statusFlags(state),
        .master_volume_fixed = state.master.selected_volume_fixed,
        .open_sessions = openSessionCount(state),
        .total_bytes_written = state.bytes_written,
        .request_ticks = state.request_last_ticks,
        .write_ticks = state.write_request_last_ticks,
    };
    copyFixed(service_result_reply.last_error[0..], spanZ(state.last_error[0..]));
    const out_bytes: [*]const u8 = @ptrCast(&service_result_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, out_bytes[0..@sizeOf(r4os.abi.AudioServiceStreamResult)]);
}

fn makeStatus(state: *const AudioServiceState) r4os.abi.AudioServiceStatus {
    var out = r4os.abi.AudioServiceStatus{
        .flags = statusFlags(state),
        .revision = state.revision,
        .master_volume_fixed = state.master.selected_volume_fixed,
        .open_sessions = openSessionCount(state),
        .peak_sessions = state.peak_sessions,
        .requests = state.requests,
        .status_requests = state.status_requests,
        .stream_open_requests = state.stream_open_requests,
        .stream_write_requests = state.stream_write_requests,
        .stream_close_requests = state.stream_close_requests,
        .set_volume_requests = state.set_volume_requests,
        .master_volume_changes = state.master_volume_changes,
        .bad_ops = state.bad_ops,
        .bytes_written = state.bytes_written,
        .backend_ok = state.backend_ok,
        .backend_fail = state.backend_fail,
        .request_total_ticks = state.request_total_ticks,
        .request_max_ticks = state.request_max_ticks,
        .request_last_ticks = state.request_last_ticks,
        .write_request_total_ticks = state.write_request_total_ticks,
        .write_request_max_ticks = state.write_request_max_ticks,
        .write_request_last_ticks = state.write_request_last_ticks,
        .last_write_bytes = state.last_write_bytes,
        .materialized_sessions = materializedSessionCount(state),
        .lazy_open_count = state.lazy_open_count,
        .silence_write_count = state.silence_write_count,
        .silence_bytes = state.silence_bytes,
        .idle_close_count = state.idle_close_count,
    };
    copyFixed(out.backend_name[0..], if (state.backend_present) "kernel-audio" else "none");
    copyFixed(out.mixer_name[0..], "SimpleKernelMixer");
    copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
}

fn makeMasterState(state: *const AudioServiceState) r4os.abi.AudioServiceMasterState {
    var flags: u32 = 0;
    if (state.master.muted) flags |= r4os.abi.audio_master_state_flag_muted;
    if (state.config_loaded) flags |= r4os.abi.audio_master_state_flag_config_loaded;
    if (state.config_defaulted) flags |= r4os.abi.audio_master_state_flag_config_defaulted;
    if (state.persist_pending) flags |= r4os.abi.audio_master_state_flag_persist_pending;
    if (state.config_error) flags |= r4os.abi.audio_master_state_flag_config_error;
    return r4os.abi.AudioServiceMasterState{
        .flags = flags,
        .service_flags = statusFlags(state),
        .master_revision = state.master.revision,
        .service_epoch = state.service_epoch,
        .selected_volume_fixed = state.master.selected_volume_fixed,
        .effective_volume_fixed = state.master.effectiveVolume(),
        .last_audible_volume_fixed = state.master.last_audible_volume_fixed,
        .persist_writes = state.persist_writes,
        .persist_failures = state.persist_failures,
        .master_changes = state.master_changes,
        .config_loads = state.config_loads,
    };
}

fn runPing(app: *const App) i32 {
    app.sys.println("AUDSVC ping");
    var handle: u32 = 0;
    if (!ensureRunningAndOpen(&app.sys, &handle)) {
        app.sys.println("AUDSVC ping failed");
        return 1;
    }
    defer _ = app.sys.serviceClose(handle);

    var status: r4os.abi.AudioServiceStatus = .{};
    if (callStatusHandle(&app.sys, handle, &status) != r4os.abi.service_api_result_ok) {
        app.sys.println("AUDSVC ping failed");
        return 1;
    }
    if (status.max_sessions != r4os.abi.audio_service_max_sessions or (status.flags & r4os.abi.audio_service_flag_service_ready) == 0) {
        app.sys.println("AUDSVC ping failed");
        return 1;
    }
    app.sys.println("AUDSVC ping: OK");
    return 0;
}

fn runSelfTest(app: *const App) i32 {
    app.sys.println("AUDSVC selftest");
    if (!app.sys.hasFn("service_start")) return fail(&app.sys, "manager-api");
    if (!app.sys.hasFn("service_call")) return fail(&app.sys, "service-api");

    var handle: u32 = 0;
    if (!ensureRunningAndOpen(&app.sys, &handle)) return fail(&app.sys, "open");
    defer _ = app.sys.serviceClose(handle);

    var status: r4os.abi.AudioServiceStatus = .{};
    if (callStatusHandle(&app.sys, handle, &status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "status");
    if (status.max_sessions != r4os.abi.audio_service_max_sessions) return fail(&app.sys, "status-shape");
    const required_audio_flags = r4os.abi.audio_service_flag_backend_present |
        r4os.abi.audio_service_flag_mixer_present;
    if ((status.flags & required_audio_flags) != required_audio_flags) return fail(&app.sys, "backend-status");

    var original_master: r4os.abi.AudioServiceMasterState = .{};
    if (app.sys.audioServiceMasterState(&original_master) != r4os.abi.service_api_result_ok) return fail(&app.sys, "master-state");

    if (app.sys.audioServiceSetMasterVolume(0x0000_8000, &status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "master-volume");
    if (status.master_volume_fixed != 0x0000_8000) return fail(&app.sys, "master-status");
    var master_request = r4os.abi.AudioServiceMasterRequest{
        .flags = r4os.abi.audio_master_request_flag_set_muted | r4os.abi.audio_master_request_flag_muted,
    };
    var master_state: r4os.abi.AudioServiceMasterState = .{};
    if (app.sys.audioServiceSetMasterState(&master_request, &master_state) != r4os.abi.service_api_result_ok or
        (master_state.flags & r4os.abi.audio_master_state_flag_muted) == 0 or master_state.effective_volume_fixed != 0)
        return fail(&app.sys, "master-mute");
    if (app.sys.audioServiceSetMasterVolume(0x0000_6000, &status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "legacy-master-muted");
    if (app.sys.audioServiceMasterState(&master_state) != r4os.abi.service_api_result_ok or
        (master_state.flags & r4os.abi.audio_master_state_flag_muted) == 0 or master_state.selected_volume_fixed != 0x0000_6000)
        return fail(&app.sys, "legacy-master-unmuted");
    master_request = .{ .flags = r4os.abi.audio_master_request_flag_set_volume, .fixed_volume = 0x0000_8000 };
    if (app.sys.audioServiceSetMasterState(&master_request, &master_state) != r4os.abi.service_api_result_ok or
        (master_state.flags & r4os.abi.audio_master_state_flag_muted) != 0 or master_state.effective_volume_fixed != 0x0000_8000)
        return fail(&app.sys, "positive-master-unmute");
    if (!waitMasterPersisted(&app.sys, original_master.persist_writes, &master_state, app.sys.ticksFromMilliseconds(persist_selftest_wait_ms)))
        return fail(&app.sys, "master-initial-persist");

    const baseline_materialized = status.materialized_sessions;
    const baseline_lazy_opens = status.lazy_open_count;
    const baseline_silence_writes = status.silence_write_count;
    const baseline_idle_closes = status.idle_close_count;
    var silence: [1024]u8 = .{0} ** 1024;
    var pcm: [1024]u8 = undefined;
    fillSquare(pcm[0..]);
    const stream = app.sys.audioServiceOpenStream(48_000, 2, .s16le);
    if (stream < 0) return fail(&app.sys, "stream-open");
    const stream_id: u32 = @intCast(stream);
    const volume = app.sys.audioServiceSetVolume(stream_id, default_volume);
    const silent_written = app.sys.audioServiceWrite(stream_id, silence[0..]);
    if (volume < 0 or silent_written != @as(i32, @intCast(silence.len))) {
        app.sys.write("AUDSVC selftest stream=");
        app.sys.printU64(stream_id);
        app.sys.write(" volume=");
        app.sys.printI32(volume);
        app.sys.write(" silence=");
        app.sys.printI32(silent_written);
        if (app.sys.audioServiceStatus(&status) == r4os.abi.service_api_result_ok) {
            app.sys.write(" sessions=");
            app.sys.printU64(status.open_sessions);
            app.sys.write(" error=");
            app.sys.write(spanZ(status.last_error[0..]));
        }
        app.sys.println("");
        return fail(&app.sys, "stream-lazy-silence");
    }
    if (app.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "silence-status");
    if (status.materialized_sessions != baseline_materialized or status.lazy_open_count != baseline_lazy_opens) return fail(&app.sys, "silence-materialized");
    if (status.silence_write_count <= baseline_silence_writes or status.silence_bytes < silence.len) return fail(&app.sys, "silence-metrics");

    const written = app.sys.audioServiceWrite(stream_id, pcm[0..]);
    if (written != @as(i32, @intCast(pcm.len))) return fail(&app.sys, "stream-signal");
    if (app.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "latency-status");
    const expected_written: u32 = @intCast(pcm.len);
    if (status.stream_write_requests == 0 or status.bytes_written < expected_written or status.last_write_bytes == 0 or status.last_write_bytes > expected_written) return fail(&app.sys, "latency-write-status");
    if (status.materialized_sessions <= baseline_materialized or status.lazy_open_count <= baseline_lazy_opens) return fail(&app.sys, "lazy-materialize");
    if (status.request_max_ticks < status.request_last_ticks or status.request_total_ticks < status.request_last_ticks) return fail(&app.sys, "latency-request-ticks");
    if (status.write_request_max_ticks < status.write_request_last_ticks or status.write_request_total_ticks < status.write_request_last_ticks) return fail(&app.sys, "latency-write-ticks");

    const idle_written = app.sys.audioServiceWrite(stream_id, silence[0..]);
    if (idle_written != @as(i32, @intCast(silence.len))) return fail(&app.sys, "idle-write");
    if (app.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "idle-status");
    if (status.materialized_sessions != baseline_materialized or status.idle_close_count <= baseline_idle_closes) return fail(&app.sys, "idle-close");
    const closed = app.sys.audioServiceClose(stream_id);
    if (closed != 0) return fail(&app.sys, "stream-close");

    const common_a = app.sys.audioServiceOpenStream(48_000, 2, .s16le);
    const common_b = app.sys.audioServiceOpenStream(48_000, 2, .s16le);
    if (common_a < 0 or common_b < 0) return fail(&app.sys, "common-master-open");
    const common_a_id: u32 = @intCast(common_a);
    const common_b_id: u32 = @intCast(common_b);
    if (app.sys.audioServiceSetVolume(common_a_id, default_volume) < 0 or
        app.sys.audioServiceSetVolume(common_b_id, 0x0000_8000) < 0 or
        app.sys.audioServiceWrite(common_a_id, pcm[0..256]) <= 0 or
        app.sys.audioServiceWrite(common_b_id, pcm[0..256]) <= 0)
        return fail(&app.sys, "common-master-materialize");
    if (app.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok or status.materialized_sessions < 2) return fail(&app.sys, "common-master-status");
    const backend_before_master = status.backend_ok;
    master_request = .{ .flags = r4os.abi.audio_master_request_flag_set_volume, .fixed_volume = 0x0000_7000 };
    if (app.sys.audioServiceSetMasterState(&master_request, &master_state) != r4os.abi.service_api_result_ok) return fail(&app.sys, "common-master-update");
    if (app.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok or status.backend_ok < backend_before_master + 2) return fail(&app.sys, "common-master-fanout");
    if (app.sys.audioServiceClose(common_a_id) != 0 or app.sys.audioServiceClose(common_b_id) != 0) return fail(&app.sys, "common-master-close");

    if (app.sys.audioServiceMasterState(&master_state) != r4os.abi.service_api_result_ok) return fail(&app.sys, "persist-baseline");
    const persist_writes_before = master_state.persist_writes;
    master_request = .{
        .flags = r4os.abi.audio_master_request_flag_set_volume | r4os.abi.audio_master_request_flag_set_muted | r4os.abi.audio_master_request_flag_muted,
        .fixed_volume = 0x0000_5000,
    };
    if (app.sys.audioServiceSetMasterState(&master_request, &master_state) != r4os.abi.service_api_result_ok) return fail(&app.sys, "persist-update");
    if (!waitMasterPersisted(&app.sys, persist_writes_before, &master_state, app.sys.ticksFromMilliseconds(persist_selftest_wait_ms))) return fail(&app.sys, "persist-write");
    const persisted_epoch = master_state.service_epoch;

    const leaky = app.sys.audioServiceOpenStream(48_000, 2, .s16le);
    if (leaky < 0) return fail(&app.sys, "restart-open");
    const leaky_id: u32 = @intCast(leaky);
    if (app.sys.audioServiceWrite(leaky_id, pcm[0..256]) <= 0) return fail(&app.sys, "restart-write");

    var info: r4os.abi.ServiceInfo = .{};
    const restart = app.sys.serviceRestart(service_name, &info);
    if (restart != r4os.abi.service_api_result_ok and restart != r4os.abi.service_api_result_running) return fail(&app.sys, "restart");
    if (!waitStatus(&app.sys, &status, 220)) return fail(&app.sys, "restart-status");
    if (status.open_sessions != 0) return fail(&app.sys, "restart-cleanup");
    if (!waitMasterState(&app.sys, &master_state, 220) or master_state.service_epoch == persisted_epoch or
        master_state.selected_volume_fixed != 0x0000_5000 or
        (master_state.flags & r4os.abi.audio_master_state_flag_muted) == 0 or master_state.effective_volume_fixed != 0)
        return fail(&app.sys, "restart-master-persisted");

    const restore_writes_before = master_state.persist_writes;
    if (!restoreMasterState(&app.sys, original_master, &master_state)) return fail(&app.sys, "master-restore");
    if (!waitMasterPersisted(&app.sys, restore_writes_before, &master_state, app.sys.ticksFromMilliseconds(persist_selftest_wait_ms))) return fail(&app.sys, "master-restore-persist");

    var bad_header: r4os.abi.ServiceMessageHeader = .{};
    var bad_response: [8]u8 = .{0} ** 8;
    var bad_handle: u32 = 0;
    if (!ensureRunningAndOpen(&app.sys, &bad_handle)) return fail(&app.sys, "bad-open");
    const bad = app.sys.serviceCall(bad_handle, 999, "", &bad_header, bad_response[0..], app.sys.ticksFromMilliseconds(500));
    _ = app.sys.serviceClose(bad_handle);
    if (bad < 0 or bad_header.status != r4os.abi.service_api_result_bad_op) return fail(&app.sys, "bad-op");

    app.sys.println("AUDSVC selftest: OK master=volume+mute streams=2 fanout=common persistence=restart");
    return 0;
}

fn ensureRunningAndOpen(ctx: *const r4os.r4sys.Context, out_handle: *u32) bool {
    var info: r4os.abi.ServiceInfo = .{};
    const status = ctx.serviceStatus(service_name, &info);
    if (status != r4os.abi.service_api_result_ok) return false;
    if (info.state != r4os.abi.service_state_running) {
        const start = ctx.serviceStart(service_name, &info);
        if (start != r4os.abi.service_api_result_ok and start != r4os.abi.service_api_result_running) return false;
    }
    return waitOpen(ctx, out_handle, 160);
}

fn waitOpen(ctx: *const r4os.r4sys.Context, out_handle: *u32, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        var info: r4os.abi.ServiceInfo = .{};
        const rc = ctx.serviceOpen(service_name, &info);
        if (rc == r4os.abi.service_api_result_ok and info.handle != 0) {
            out_handle.* = info.handle;
            return true;
        }
        ctx.sleepTicks(1);
    }
    return false;
}

fn waitStatus(ctx: *const r4os.r4sys.Context, out: *r4os.abi.AudioServiceStatus, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (ctx.audioServiceStatus(out) == r4os.abi.service_api_result_ok) return true;
        ctx.sleepTicks(1);
    }
    return false;
}

fn waitMasterState(ctx: *const r4os.r4sys.Context, out: *r4os.abi.AudioServiceMasterState, max_ticks: u32) bool {
    var tick: u32 = 0;
    while (tick < max_ticks) : (tick += 1) {
        if (ctx.audioServiceMasterState(out) == r4os.abi.service_api_result_ok) return true;
        ctx.sleepTicks(1);
    }
    return false;
}

fn waitMasterPersisted(ctx: *const r4os.r4sys.Context, baseline_writes: u64, out: *r4os.abi.AudioServiceMasterState, max_ticks: u64) bool {
    const poll_ticks = @max(ctx.ticksFromMilliseconds(persist_poll_ms), 1);
    const started = ctx.ticks();
    while (ctx.ticks() -| started < max_ticks) {
        if (ctx.audioServiceMasterState(out) == r4os.abi.service_api_result_ok and
            out.persist_writes > baseline_writes and
            (out.flags & r4os.abi.audio_master_state_flag_persist_pending) == 0)
            return true;
        ctx.sleepTicks(poll_ticks);
    }
    return false;
}

fn restoreMasterState(ctx: *const r4os.r4sys.Context, original: r4os.abi.AudioServiceMasterState, out: *r4os.abi.AudioServiceMasterState) bool {
    var request = r4os.abi.AudioServiceMasterRequest{
        .flags = r4os.abi.audio_master_request_flag_set_volume,
        .fixed_volume = original.last_audible_volume_fixed,
    };
    if (ctx.audioServiceSetMasterState(&request, out) != r4os.abi.service_api_result_ok) return false;
    request = .{
        .flags = r4os.abi.audio_master_request_flag_set_volume | r4os.abi.audio_master_request_flag_set_muted |
            (if ((original.flags & r4os.abi.audio_master_state_flag_muted) != 0) r4os.abi.audio_master_request_flag_muted else 0),
        .fixed_volume = original.selected_volume_fixed,
    };
    return ctx.audioServiceSetMasterState(&request, out) == r4os.abi.service_api_result_ok;
}

fn callStatusHandle(ctx: *const r4os.r4sys.Context, handle: u32, out: *r4os.abi.AudioServiceStatus) i32 {
    var header: r4os.abi.ServiceMessageHeader = .{};
    var response: [@sizeOf(r4os.abi.AudioServiceStatus)]u8 = .{0} ** @sizeOf(r4os.abi.AudioServiceStatus);
    const got = ctx.serviceCall(handle, r4os.abi.audio_service_op_status, "", &header, response[0..], ctx.ticksFromMilliseconds(1000));
    if (got < 0) return got;
    if (header.status != r4os.abi.service_api_result_ok) return header.status;
    if (got < @as(i32, @intCast(@sizeOf(r4os.abi.AudioServiceStatus)))) return r4os.abi.service_api_result_buffer_too_small;
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..@sizeOf(r4os.abi.AudioServiceStatus)], response[0..@sizeOf(r4os.abi.AudioServiceStatus)]);
    if (out.magic != r4os.abi.audio_service_status_magic or out.version != r4os.abi.audio_service_status_version) return r4os.abi.service_api_result_invalid;
    return r4os.abi.service_api_result_ok;
}

fn parseVolumeRequest(payload: []const u8, out: *r4os.abi.AudioServiceVolumeRequest) bool {
    if (payload.len < @sizeOf(r4os.abi.AudioServiceVolumeRequest)) return false;
    copyStruct(out, payload[0..@sizeOf(r4os.abi.AudioServiceVolumeRequest)]);
    return out.magic == r4os.abi.audio_service_request_magic and out.version == r4os.abi.audio_service_request_version;
}

fn parseMasterRequest(payload: []const u8, out: *r4os.abi.AudioServiceMasterRequest) bool {
    if (payload.len != @sizeOf(r4os.abi.AudioServiceMasterRequest)) return false;
    copyStruct(out, payload);
    const set_flags = r4os.abi.audio_master_request_flag_set_volume | r4os.abi.audio_master_request_flag_set_muted;
    const known_flags = set_flags | r4os.abi.audio_master_request_flag_muted;
    if (out.magic != r4os.abi.audio_master_request_magic or
        out.version != r4os.abi.audio_master_request_version or
        out.size != @sizeOf(r4os.abi.AudioServiceMasterRequest) or
        (out.flags & ~known_flags) != 0 or
        (out.flags & set_flags) == 0 or
        ((out.flags & r4os.abi.audio_master_request_flag_muted) != 0 and (out.flags & r4os.abi.audio_master_request_flag_set_muted) == 0)) return false;
    for (out.reserved0) |value| if (value != 0) return false;
    return true;
}

fn parseOpenRequest(payload: []const u8, out: *r4os.abi.AudioServiceStreamOpenRequest) bool {
    if (payload.len < @sizeOf(r4os.abi.AudioServiceStreamOpenRequest)) return false;
    copyStruct(out, payload[0..@sizeOf(r4os.abi.AudioServiceStreamOpenRequest)]);
    return out.magic == r4os.abi.audio_service_request_magic and out.version == r4os.abi.audio_service_request_version;
}

fn parseWriteRequest(payload: []const u8, out: *r4os.abi.AudioServiceStreamWriteRequest) bool {
    if (payload.len < @sizeOf(r4os.abi.AudioServiceStreamWriteRequest)) return false;
    copyStruct(out, payload[0..@sizeOf(r4os.abi.AudioServiceStreamWriteRequest)]);
    return out.magic == r4os.abi.audio_service_request_magic and out.version == r4os.abi.audio_service_request_version;
}

fn parseControlRequest(payload: []const u8, out: *r4os.abi.AudioServiceStreamControlRequest) bool {
    if (payload.len < @sizeOf(r4os.abi.AudioServiceStreamControlRequest)) return false;
    copyStruct(out, payload[0..@sizeOf(r4os.abi.AudioServiceStreamControlRequest)]);
    return out.magic == r4os.abi.audio_service_request_magic and out.version == r4os.abi.audio_service_request_version;
}

fn copyStruct(out: anytype, payload: []const u8) void {
    const out_bytes: [*]u8 = @ptrCast(out);
    @memcpy(out_bytes[0..payload.len], payload);
}

fn loadMasterConfiguration(app: *const App, state: *AudioServiceState) void {
    var bytes: [512]u8 = undefined;
    if (!app.sys.exists(master_config_path)) {
        state.config_defaulted = true;
        copyFixed(state.last_error[0..], "config-default");
        return;
    }
    const got = app.sys.fileRead(master_config_path, bytes[0..]);
    if (got <= 0 or got > @as(i32, @intCast(bytes.len))) {
        state.config_defaulted = true;
        state.config_error = true;
        copyFixed(state.last_error[0..], "config-read-failed");
        return;
    }
    const persisted = master_control.parse(bytes[0..@intCast(got)]) orelse {
        state.config_defaulted = true;
        state.config_error = true;
        copyFixed(state.last_error[0..], "config-corrupt");
        return;
    };
    master_control.restore(&state.master, persisted);
    state.last_persisted = persisted;
    state.config_loaded = true;
    state.config_loads = 1;
    copyFixed(state.last_error[0..], "config-loaded");
}

fn scheduleMasterPersistence(app: *const App, state: *AudioServiceState) void {
    const snapshot = master_control.snapshot(state.master);
    var generation = @atomicLoad(u64, &state.persistence.target_generation, .acquire) +% 1;
    if (generation == 0) generation = 1;
    const delay = @max(app.sys.ticksFromMilliseconds(persist_debounce_ms), 1);
    const due_tick = app.sys.ticks() +| delay;
    @atomicStore(u32, &state.persistence.target_selected_volume_fixed, snapshot.selected_volume_fixed, .monotonic);
    @atomicStore(u32, &state.persistence.target_last_audible_volume_fixed, snapshot.last_audible_volume_fixed, .monotonic);
    @atomicStore(u32, &state.persistence.target_muted, @intFromBool(snapshot.muted), .monotonic);
    @atomicStore(u64, &state.persistence.target_due_tick, due_tick, .monotonic);
    @atomicStore(u64, &state.persistence.target_generation, generation, .release);
    state.persist_pending = true;
    state.persist_due_tick = due_tick;
    // Start the single worker while the request that changed the setting is
    // still being handled.  The worker itself observes target_due_tick, so
    // rapid changes remain debounced and coalesced without depending on the
    // service loop reaching its next housekeeping pass in time.
    if (!state.persistence.in_flight) startMasterPersistence(app, state);
}

fn serviceMasterPersistence(app: *const App, state: *AudioServiceState) void {
    const now = app.sys.ticks();
    _ = joinMasterPersistence(app, state, 0);
    if (!state.persist_pending or state.persistence.in_flight) return;
    if (now < state.persist_due_tick) return;
    startMasterPersistence(app, state);
}

fn startMasterPersistence(app: *const App, state: *AudioServiceState) void {
    if (!state.persist_pending or state.persistence.in_flight) return;
    const snapshot = master_control.snapshot(state.master);
    if (persistedEqual(snapshot, state.last_persisted)) {
        state.persist_pending = false;
        copyFixed(state.last_error[0..], "config-save-coalesced");
        return;
    }
    if (!app.sys.hasFn("thread_create_handle") or !app.sys.hasFn("thread_handle_join")) {
        recordPersistFailure(app, state, "config-worker-unavailable");
        return;
    }
    state.persistence.sys = app.sys;
    state.persistence.thread_handle = .{};
    var thread_handle: r4os.abi.ProgramJoinHandle = .{};
    const rc = app.sys.threadCreateHandle(persistenceWorkerMain, @intFromPtr(&state.persistence), 0, 0, &thread_handle);
    if (rc != r4os.abi.thread_ok) {
        recordPersistFailure(app, state, "config-worker-start-failed");
        return;
    }
    state.persistence.thread_handle = thread_handle;
    state.persistence.in_flight = true;
}

fn joinMasterPersistence(app: *const App, state: *AudioServiceState, timeout_ticks: u64) bool {
    if (!state.persistence.in_flight) return false;
    var exit_code: i32 = 1;
    const rc = app.sys.threadHandleJoin(&state.persistence.thread_handle, timeout_ticks, &exit_code);
    if (rc == r4os.abi.thread_error_timeout or rc == r4os.abi.thread_error_busy) return false;

    const saved_snapshot = state.persistence.completed_snapshot;
    state.persistence.in_flight = false;
    state.persistence.thread_handle = .{};
    if (rc != r4os.abi.thread_ok or exit_code != 0) {
        recordPersistFailure(app, state, "config-save-failed");
        return true;
    }

    state.persist_writes +%= 1;
    state.config_error = false;
    state.last_persisted = saved_snapshot;
    if (persistedEqual(master_control.snapshot(state.master), saved_snapshot)) state.persist_pending = false;
    copyFixed(state.last_error[0..], if (state.persist_pending) "config-save-coalesced" else "config-saved");
    return true;
}

fn flushMasterPersistence(app: *const App, state: *AudioServiceState) void {
    if (state.persistence.in_flight) _ = joinMasterPersistence(app, state, r4os.abi.io_wait_forever);
    if (!state.persist_pending) return;
    state.persist_due_tick = app.sys.ticks();
    @atomicStore(u64, &state.persistence.target_due_tick, state.persist_due_tick, .release);
    startMasterPersistence(app, state);
    if (state.persistence.in_flight) _ = joinMasterPersistence(app, state, r4os.abi.io_wait_forever);
}

fn persistenceWorkerMain(raw_job: u64) callconv(.c) i32 {
    const job: *PersistenceJob = @ptrFromInt(raw_job);
    const poll_ticks = @max(job.sys.ticksFromMilliseconds(persist_poll_ms), 1);
    while (true) {
        const generation = @atomicLoad(u64, &job.target_generation, .acquire);
        if (generation == 0) return 2;

        while (true) {
            if (@atomicLoad(u64, &job.target_generation, .acquire) != generation) break;
            const due_tick = @atomicLoad(u64, &job.target_due_tick, .acquire);
            const now = job.sys.ticks();
            if (now >= due_tick) break;
            job.sys.sleepTicks(@min(poll_ticks, due_tick - now));
        }
        if (@atomicLoad(u64, &job.target_generation, .acquire) != generation) continue;

        const snapshot = master_control.Persisted{
            .selected_volume_fixed = @atomicLoad(u32, &job.target_selected_volume_fixed, .acquire),
            .last_audible_volume_fixed = @atomicLoad(u32, &job.target_last_audible_volume_fixed, .acquire),
            .muted = @atomicLoad(u32, &job.target_muted, .acquire) != 0,
        };
        if (@atomicLoad(u64, &job.target_generation, .acquire) != generation) continue;

        var bytes: [256]u8 = undefined;
        const encoded = master_control.encode(snapshot, bytes[0..]) orelse return 2;
        if (!saveMasterDocument(&job.sys, encoded)) return 1;
        job.completed_snapshot = snapshot;
        if (@atomicLoad(u64, &job.target_generation, .acquire) == generation) return 0;
    }
}

fn saveMasterDocument(ctx: *const r4os.r4sys.Context, bytes: []const u8) bool {
    _ = ctx.dirCreate("C:\\R4OS\\CONFIG");
    _ = ctx.fileDelete(master_config_stage_path);
    _ = ctx.fileDelete(master_config_backup_path);

    if (ctx.fileWrite(master_config_stage_path, bytes) != @as(i32, @intCast(bytes.len))) {
        _ = ctx.fileDelete(master_config_stage_path);
        return false;
    }
    if (!masterDocumentMatches(ctx, master_config_stage_path, bytes)) {
        _ = ctx.fileDelete(master_config_stage_path);
        return false;
    }

    var replaced = ctx.fileReplaceAtomic(
        master_config_path,
        master_config_stage_path,
        master_config_backup_path,
        r4os.r4sys.file_replace_atomic_flag_consume_stage,
    );
    if (replaced == r4os.r4sys.file_replace_atomic_error_io) {
        replaced = ctx.fileReplaceAtomic(
            master_config_path,
            master_config_stage_path,
            master_config_backup_path,
            r4os.r4sys.file_replace_atomic_flag_consume_stage,
        );
    }
    if (replaced != r4os.r4sys.file_replace_atomic_result_ok and
        !masterDocumentMatches(ctx, master_config_path, bytes))
        return false;
    if (!masterDocumentMatches(ctx, master_config_path, bytes)) return false;

    _ = ctx.fileDelete(master_config_stage_path);
    _ = ctx.fileDelete(master_config_backup_path);
    return true;
}

fn masterDocumentMatches(ctx: *const r4os.r4sys.Context, path: [*:0]const u8, expected: []const u8) bool {
    var verify: [256]u8 = undefined;
    const read = ctx.fileRead(path, verify[0..]);
    return read == @as(i32, @intCast(expected.len)) and
        std.mem.eql(u8, verify[0..expected.len], expected);
}

fn persistedEqual(a: master_control.Persisted, b: master_control.Persisted) bool {
    return a.selected_volume_fixed == b.selected_volume_fixed and
        a.last_audible_volume_fixed == b.last_audible_volume_fixed and
        a.muted == b.muted;
}

fn recordPersistFailure(app: *const App, state: *AudioServiceState, message: []const u8) void {
    state.persist_pending = true;
    state.persist_failures +%= 1;
    state.config_error = true;
    const delay = @max(app.sys.ticksFromMilliseconds(persist_retry_ms), 1);
    state.persist_due_tick = app.sys.ticks() +| delay;
    @atomicStore(u64, &state.persistence.target_due_tick, state.persist_due_tick, .release);
    copyFixed(state.last_error[0..], message);
}

fn applyMasterToStreams(app: *const App, state: *AudioServiceState) void {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (!state.sessions[i].open or state.sessions[i].backend_stream_id == 0) continue;
        const result = app.audio.audioSetVolume(state.sessions[i].backend_stream_id, effectiveVolume(state, state.sessions[i].fixed_volume));
        if (result >= 0) {
            state.backend_ok +%= 1;
        } else {
            state.backend_fail +%= 1;
            copyFixed(state.last_error[0..], "master-apply-failed");
        }
    }
}

fn closeOpenSessions(app: *const App, state: *AudioServiceState) void {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (!state.sessions[i].open) continue;
        if (state.sessions[i].backend_stream_id != 0) _ = app.audio.audioClose(state.sessions[i].backend_stream_id);
        state.sessions[i] = .{};
    }
    bumpRevision(state);
}

fn freeSession(state: *const AudioServiceState) ?usize {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (!state.sessions[i].open) return i;
    }
    return null;
}

fn allocateStreamId(state: *AudioServiceState) ?u32 {
    var attempts: usize = 0;
    while (attempts <= state.sessions.len) : (attempts += 1) {
        const candidate = state.next_stream_id;
        state.next_stream_id +%= 1;
        if (state.next_stream_id == 0) state.next_stream_id = 1;
        if (candidate != 0 and sessionSlotById(state, candidate) == null) return candidate;
    }
    return null;
}

fn sessionSlotById(state: *const AudioServiceState, stream_id: u32) ?usize {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open and state.sessions[i].stream_id == stream_id) return i;
    }
    return null;
}

fn materializeSession(app: *const App, state: *AudioServiceState, session: *Session) i32 {
    if (session.backend_stream_id != 0) return 0;
    refreshBackendState(app, state);
    if (!state.backend_present) {
        copyFixed(state.last_error[0..], "no-backend");
        return r4os.abi.service_api_result_no_endpoint;
    }
    const stream = app.audio.audioOpenStream(session.rate, session.channels, .s16le);
    if (stream < 0) {
        state.backend_fail +%= 1;
        copyFixed(state.last_error[0..], "open-failed");
        return stream;
    }
    const backend_stream_id: u32 = @intCast(stream);
    const volume_result = app.audio.audioSetVolume(backend_stream_id, effectiveVolume(state, session.fixed_volume));
    if (volume_result < 0) {
        _ = app.audio.audioClose(backend_stream_id);
        state.backend_fail +%= 1;
        copyFixed(state.last_error[0..], "volume-failed");
        return volume_result;
    }
    session.backend_stream_id = backend_stream_id;
    state.lazy_open_count +%= 1;
    state.backend_ok +%= 1;
    copyFixed(state.last_error[0..], "stream-materialized");
    bumpRevision(state);
    return 0;
}

fn sessionByStream(state: *AudioServiceState, client_id: u32, stream_id: u32) ?*Session {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open and session_ownership.matches(state.sessions[i].client_id, state.sessions[i].stream_id, client_id, stream_id)) return &state.sessions[i];
    }
    return null;
}

fn sessionSlotByStream(state: *const AudioServiceState, client_id: u32, stream_id: u32) ?usize {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open and session_ownership.matches(state.sessions[i].client_id, state.sessions[i].stream_id, client_id, stream_id)) return i;
    }
    return null;
}

fn refreshBackendState(app: *const App, state: *AudioServiceState) void {
    const performance = app.devices.performance();
    const summary = performance.summary() orelse {
        state.backend_present = false;
        return;
    };
    state.backend_present = summary.audio_active_backends > 0;
}

fn reapDisconnectedSessions(app: *const App, state: *AudioServiceState) void {
    var owners: [max_sessions]session_ownership.Owner = undefined;
    var generations: [max_sessions]u64 = undefined;
    var count: usize = 0;
    for (state.sessions) |session| {
        if (!session.open) continue;
        owners[count] = .{ .id = session.client_id, .generation = session.client_generation };
        count += 1;
    }
    var reader = ClientInventory{ .ctx = &app.sys };
    if (!session_ownership.collectRunning(owners[0..count], generations[0..count], &reader)) return;
    var changed = false;
    var owner_index: usize = 0;
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        const session = &state.sessions[i];
        if (!session.open) continue;
        const running_generation = generations[owner_index];
        owner_index += 1;
        if (running_generation != 0) continue;
        const rc = if (session.backend_stream_id == 0) 0 else app.audio.audioClose(session.backend_stream_id);
        if (rc < 0) {
            state.backend_fail +%= 1;
            copyFixed(state.last_error[0..], "reap-failed");
            continue;
        }
        session.* = .{};
        changed = true;
    }
    if (changed) {
        copyFixed(state.last_error[0..], "client-disconnect");
        bumpRevision(state);
    }
}

const ClientInventory = struct {
    ctx: *const r4os.r4sys.Context,
    cursor: r4os.abi.ProgramInventoryCursor = .{},
    items: [16]r4os.abi.ProgramInstanceSnapshot = undefined,
    records: [16]session_ownership.Record = undefined,

    pub fn begin(self: *ClientInventory) bool {
        var summary: r4os.abi.ProgramInventorySummary = .{};
        return self.ctx.programInventoryBegin(&self.cursor, &summary) == r4os.abi.program_handle_ok;
    }
    pub fn next(self: *ClientInventory) ?session_ownership.Page {
        var page: r4os.abi.ProgramInventoryPageInfo = .{};
        if (self.ctx.programInventoryPrograms(&self.cursor, &self.items, &page) != r4os.abi.program_handle_ok or
            page.snapshot_generation != self.cursor.snapshot_generation or page.returned > self.items.len or
            (page.status != r4os.abi.program_inventory_status_complete and page.status != r4os.abi.program_inventory_status_more)) return null;
        for (self.items[0..page.returned], 0..) |item, i| {
            self.records[i] = .{
                .owner = .{ .id = item.handle.instance_id, .generation = item.handle.generation },
                .running = item.info.state == program_instance_state_running,
            };
        }
        return .{ .records = self.records[0..page.returned], .complete = page.status == r4os.abi.program_inventory_status_complete };
    }
};

fn openSessionCount(state: *const AudioServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open) count += 1;
    }
    return count;
}

fn materializedSessionCount(state: *const AudioServiceState) u32 {
    var count: u32 = 0;
    for (state.sessions) |session| {
        if (session.open and session.backend_stream_id != 0) count += 1;
    }
    return count;
}

fn updatePeak(state: *AudioServiceState) void {
    const count = openSessionCount(state);
    if (count > state.peak_sessions) state.peak_sessions = count;
}

fn statusFlags(state: *const AudioServiceState) u32 {
    var flags = r4os.abi.audio_service_flag_service_ready |
        r4os.abi.audio_service_flag_mixer_present;
    if (state.backend_present) flags |= r4os.abi.audio_service_flag_backend_present;
    if (openSessionCount(state) > 0) flags |= r4os.abi.audio_service_flag_sessions_open;
    return flags;
}

fn effectiveVolume(state: *const AudioServiceState, fixed_volume: u32) u32 {
    return scaleVolume(fixed_volume, state.master.effectiveVolume());
}

fn scaleVolume(stream_volume: u32, master_volume: u32) u32 {
    const scaled = (@as(u64, stream_volume) * @as(u64, master_volume)) >> 16;
    return if (scaled > 0xFFFF_FFFF) 0xFFFF_FFFF else @intCast(scaled);
}

fn bumpRevision(state: *AudioServiceState) void {
    state.revision +%= 1;
    if (state.revision == 0) state.revision = 1;
}

fn recordRequestTicks(app: *const App, state: *AudioServiceState, op: u16, start_tick: u64) void {
    const now = app.sys.ticks();
    const elapsed = if (now >= start_tick) now - start_tick else 0;
    state.request_total_ticks +%= elapsed;
    state.request_last_ticks = elapsed;
    if (elapsed > state.request_max_ticks) state.request_max_ticks = elapsed;
    if (op == r4os.abi.audio_service_op_write_stream) {
        state.write_request_total_ticks +%= elapsed;
        state.write_request_last_ticks = elapsed;
        if (elapsed > state.write_request_max_ticks) state.write_request_max_ticks = elapsed;
    }
}

fn fillSquare(out: []u8) void {
    var frame: usize = 0;
    while (frame < out.len / 4) : (frame += 1) {
        const sample: i16 = if (((frame / 16) & 1) == 0) 2400 else -2400;
        writeI16(out, frame * 4, sample);
        writeI16(out, frame * 4 + 2, sample);
    }
}

fn writeI16(out: []u8, index: usize, sample: i16) void {
    const bits: u16 = @bitCast(sample);
    out[index] = @intCast(bits & 0xFF);
    out[index + 1] = @intCast(bits >> 8);
}

fn fail(ctx: *const r4os.r4sys.Context, label: []const u8) i32 {
    ctx.write("AUDSVC selftest FAILED: ");
    ctx.println(label);
    return 1;
}

fn hasArg(args: [*:0]const u8, wanted: []const u8) bool {
    var offset: usize = 0;
    while (offset < 256 and args[offset] != 0) {
        while (offset < 256 and (args[offset] == ' ' or args[offset] == '\t')) : (offset += 1) {}
        const start = offset;
        while (offset < 256 and args[offset] != 0 and args[offset] != ' ' and args[offset] != '\t') : (offset += 1) {}
        if (equalsIgnoreCase(args[start..offset], wanted)) return true;
    }
    return false;
}

fn equalsIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (upper(a[i]) != upper(b[i])) return false;
    }
    return true;
}

fn upper(ch: u8) u8 {
    return if (ch >= 'a' and ch <= 'z') ch - 32 else ch;
}

fn copyFixed(out: []u8, value: []const u8) void {
    if (out.len == 0) return;
    @memset(out, 0);
    const count = @min(value.len, out.len - 1);
    if (count > 0) @memcpy(out[0..count], value[0..count]);
    out[count] = 0;
}

fn spanZ(buffer: []const u8) []const u8 {
    var len: usize = 0;
    while (len < buffer.len and buffer[len] != 0) : (len += 1) {}
    return buffer[0..len];
}
