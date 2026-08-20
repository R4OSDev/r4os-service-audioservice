const r4os = @import("r4os");

const service_name = "AUDSVC";
const selftest_arg = "/SELFTEST";
const ping_arg = "/PING";
const default_volume: u32 = 0x0001_0000;
const max_sessions: usize = @intCast(r4os.abi.audio_service_max_sessions);

// Non-zero initializer keeps the R4X scratch buffer file-backed instead of BSS-only.
var service_payload_buffer: [r4os.abi.service_api_max_payload]u8 = .{0xA5} ** r4os.abi.service_api_max_payload;
var service_status_reply: r4os.abi.AudioServiceStatus = .{};
var service_result_reply: r4os.abi.AudioServiceStreamResult = .{};

const App = struct {
    sys: r4os.r4sys.Context,
    audio: r4os.r4audio.Context,

    fn init(r4_app: *r4os.App) ?App {
        return .{
            .sys = r4_app.system(),
            .audio = r4_app.audioLowLevel() orelse return null,
        };
    }
};

const Session = struct {
    open: bool = false,
    client_id: u32 = 0,
    stream_id: u32 = 0,
    rate: u32 = 0,
    channels: u16 = 0,
    format: u16 = 0,
    fixed_volume: u32 = default_volume,
    writes: u64 = 0,
    bytes_written: u64 = 0,
};

const AudioServiceState = struct {
    sessions: [max_sessions]Session = .{Session{}} ** max_sessions,
    revision: u32 = 1,
    master_volume_fixed: u32 = default_volume,
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
    peak_sessions: u32 = 0,
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

    var state = AudioServiceState{};
    copyFixed(state.last_error[0..], "ready");

    while (!app.sys.programShouldClose()) {
        const poll = app.sys.serviceEndpointPoll(handle);
        if (poll < 0) {
            closeOpenSessions(app, &state);
            _ = app.sys.serviceEndpointUnregister(handle);
            return poll;
        }
        if (poll > 0) {
            const rc = handleRequest(app, handle, &state);
            if (rc < 0 and rc != r4os.abi.service_api_result_not_found) {
                closeOpenSessions(app, &state);
                _ = app.sys.serviceEndpointUnregister(handle);
                return rc;
            }
        }
        app.sys.sleepTicks(1);
    }

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
        r4os.abi.audio_service_op_open_stream => handleOpenStream(app, handle, header.request_id, header.client_id, state, payload, request_start),
        r4os.abi.audio_service_op_write_stream => handleWriteStream(app, handle, header.request_id, state, payload, request_start),
        r4os.abi.audio_service_op_close_stream => handleCloseStream(app, handle, header.request_id, state, payload, request_start),
        r4os.abi.audio_service_op_set_stream_volume => handleSetStreamVolume(app, handle, header.request_id, state, payload, request_start),
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

    state.master_volume_fixed = request.fixed_volume;
    state.master_volume_changes +%= 1;
    copyFixed(state.last_error[0..], "master-volume");
    bumpRevision(state);

    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (!state.sessions[i].open) continue;
        const rc = app.audio.audioSetVolume(state.sessions[i].stream_id, effectiveVolume(state, state.sessions[i].fixed_volume));
        if (rc >= 0) {
            state.backend_ok +%= 1;
        } else {
            state.backend_fail +%= 1;
        }
    }

    return replyStatus(app, handle, request_id, state, request_start);
}

fn handleOpenStream(app: *const App, handle: u32, request_id: u32, client_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamOpenRequest = .{};
    state.stream_open_requests +%= 1;
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

    const stream = app.audio.audioOpenStream(request.rate, request.channels, .s16le);
    if (stream < 0) {
        state.backend_fail +%= 1;
        copyFixed(state.last_error[0..], "open-failed");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, stream, 0, 0, request_start);
    }

    const stream_id: u32 = @intCast(stream);
    _ = app.audio.audioSetVolume(stream_id, scaleVolume(request.fixed_volume, state.master_volume_fixed));
    state.sessions[slot] = .{
        .open = true,
        .client_id = client_id,
        .stream_id = stream_id,
        .rate = request.rate,
        .channels = request.channels,
        .format = request.format,
        .fixed_volume = request.fixed_volume,
    };
    updatePeak(state);
    state.backend_ok +%= 1;
    copyFixed(state.last_error[0..], "stream-open");
    bumpRevision(state);
    const reply = replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_open_stream, stream, stream_id, 0, request_start);
    if (reply < 0) {
        _ = app.audio.audioClose(stream_id);
        state.sessions[slot] = .{};
        copyFixed(state.last_error[0..], "open-abandoned");
        bumpRevision(state);
    }
    return reply;
}

fn handleWriteStream(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamWriteRequest = .{};
    state.stream_write_requests +%= 1;
    const header_size = @sizeOf(r4os.abi.AudioServiceStreamWriteRequest);
    if (payload.len < header_size or !parseWriteRequest(payload[0..header_size], &request)) {
        copyFixed(state.last_error[0..], "bad-write");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    if (request.byte_count > payload.len - header_size) {
        copyFixed(state.last_error[0..], "short-write");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, r4os.abi.service_api_result_invalid, request.stream_id, 0, request_start);
    }
    const data = payload[header_size .. header_size + @as(usize, @intCast(request.byte_count))];
    const session = sessionByStream(state, request.stream_id) orelse {
        copyFixed(state.last_error[0..], "bad-stream");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_write_stream, -1, request.stream_id, 0, request_start);
    };

    const written = app.audio.audioWrite(request.stream_id, data);
    if (written < 0) {
        if (written == r4os.abi.service_api_result_busy) {
            copyFixed(state.last_error[0..], "write-busy");
        } else {
            state.backend_fail +%= 1;
            copyFixed(state.last_error[0..], "write-failed");
        }
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

fn handleCloseStream(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamControlRequest = .{};
    state.stream_close_requests +%= 1;
    if (!parseControlRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-close");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_close_stream, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    const slot = sessionSlotByStream(state, request.stream_id) orelse {
        copyFixed(state.last_error[0..], "bad-stream");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_close_stream, -1, request.stream_id, 0, request_start);
    };

    const rc = app.audio.audioClose(request.stream_id);
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

fn handleSetStreamVolume(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, payload: []const u8, request_start: u64) i32 {
    var request: r4os.abi.AudioServiceStreamControlRequest = .{};
    state.set_volume_requests +%= 1;
    if (!parseControlRequest(payload, &request)) {
        copyFixed(state.last_error[0..], "bad-volume");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_set_stream_volume, r4os.abi.service_api_result_invalid, 0, 0, request_start);
    }
    const session = sessionByStream(state, request.stream_id) orelse {
        copyFixed(state.last_error[0..], "bad-stream");
        return replyResult(app, handle, request_id, state, r4os.abi.audio_service_op_set_stream_volume, -1, request.stream_id, 0, request_start);
    };
    session.fixed_volume = request.fixed_volume;
    const rc = app.audio.audioSetVolume(request.stream_id, effectiveVolume(state, request.fixed_volume));
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
    state.status_requests +%= 1;
    recordRequestTicks(app, state, r4os.abi.audio_service_op_status, request_start);
    service_status_reply = makeStatus(state);
    const bytes: [*]const u8 = @ptrCast(&service_status_reply);
    return app.sys.serviceEndpointReply(handle, request_id, r4os.abi.service_api_result_ok, bytes[0..@sizeOf(r4os.abi.AudioServiceStatus)]);
}

fn replyResult(app: *const App, handle: u32, request_id: u32, state: *AudioServiceState, action: u16, result: i32, stream_id: u32, bytes: u32, request_start: u64) i32 {
    recordRequestTicks(app, state, action, request_start);
    service_result_reply = r4os.abi.AudioServiceStreamResult{
        .action = action,
        .result = result,
        .stream_id = stream_id,
        .bytes = bytes,
        .flags = statusFlags(state),
        .master_volume_fixed = state.master_volume_fixed,
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
        .master_volume_fixed = state.master_volume_fixed,
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
    };
    copyFixed(out.backend_name[0..], "kernel-audio");
    copyFixed(out.mixer_name[0..], "AUDSVC/SimpleKernelMixer");
    copyFixed(out.last_error[0..], spanZ(state.last_error[0..]));
    return out;
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

    if (app.sys.audioServiceSetMasterVolume(0x0000_8000, &status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "master-volume");
    if (status.master_volume_fixed != 0x0000_8000) return fail(&app.sys, "master-status");

    var pcm: [1024]u8 = undefined;
    fillSquare(pcm[0..]);
    const stream = app.sys.audioServiceOpenStream(48_000, 2, .s16le);
    if (stream < 0) return fail(&app.sys, "stream-open");
    const stream_id: u32 = @intCast(stream);
    const volume = app.sys.audioServiceSetVolume(stream_id, default_volume);
    const written = app.sys.audioServiceWrite(stream_id, pcm[0..]);
    const closed = app.sys.audioServiceClose(stream_id);
    if (volume < 0 or written != @as(i32, @intCast(pcm.len)) or closed != 0) return fail(&app.sys, "stream-cycle");
    if (app.sys.audioServiceStatus(&status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "latency-status");
    const expected_written: u32 = @intCast(pcm.len);
    if (status.stream_write_requests == 0 or status.bytes_written < expected_written or status.last_write_bytes == 0 or status.last_write_bytes > expected_written) return fail(&app.sys, "latency-write-status");
    if (status.request_max_ticks < status.request_last_ticks or status.request_total_ticks < status.request_last_ticks) return fail(&app.sys, "latency-request-ticks");
    if (status.write_request_max_ticks < status.write_request_last_ticks or status.write_request_total_ticks < status.write_request_last_ticks) return fail(&app.sys, "latency-write-ticks");

    const leaky = app.sys.audioServiceOpenStream(48_000, 2, .s16le);
    if (leaky < 0) return fail(&app.sys, "restart-open");
    const leaky_id: u32 = @intCast(leaky);
    if (app.sys.audioServiceWrite(leaky_id, pcm[0..256]) <= 0) return fail(&app.sys, "restart-write");

    var info: r4os.abi.ServiceInfo = .{};
    const restart = app.sys.serviceRestart(service_name, &info);
    if (restart != r4os.abi.service_api_result_ok and restart != r4os.abi.service_api_result_running) return fail(&app.sys, "restart");
    if (!waitStatus(&app.sys, &status, 220)) return fail(&app.sys, "restart-status");
    if (status.open_sessions != 0) return fail(&app.sys, "restart-cleanup");

    if (app.sys.audioServiceSetMasterVolume(default_volume, &status) != r4os.abi.service_api_result_ok) return fail(&app.sys, "master-reset");
    if (status.master_volume_fixed != default_volume) return fail(&app.sys, "master-reset-status");

    var bad_header: r4os.abi.ServiceMessageHeader = .{};
    var bad_response: [8]u8 = .{0} ** 8;
    var bad_handle: u32 = 0;
    if (!ensureRunningAndOpen(&app.sys, &bad_handle)) return fail(&app.sys, "bad-open");
    const bad = app.sys.serviceCall(bad_handle, 999, "", &bad_header, bad_response[0..], app.sys.ticksFromMilliseconds(500));
    _ = app.sys.serviceClose(bad_handle);
    if (bad < 0 or bad_header.status != r4os.abi.service_api_result_bad_op) return fail(&app.sys, "bad-op");

    app.sys.println("AUDSVC selftest: OK");
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

fn closeOpenSessions(app: *const App, state: *AudioServiceState) void {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (!state.sessions[i].open) continue;
        _ = app.audio.audioClose(state.sessions[i].stream_id);
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

fn sessionByStream(state: *AudioServiceState, stream_id: u32) ?*Session {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open and state.sessions[i].stream_id == stream_id) return &state.sessions[i];
    }
    return null;
}

fn sessionSlotByStream(state: *const AudioServiceState, stream_id: u32) ?usize {
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open and state.sessions[i].stream_id == stream_id) return i;
    }
    return null;
}

fn openSessionCount(state: *const AudioServiceState) u32 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < state.sessions.len) : (i += 1) {
        if (state.sessions[i].open) count += 1;
    }
    return count;
}

fn updatePeak(state: *AudioServiceState) void {
    const count = openSessionCount(state);
    if (count > state.peak_sessions) state.peak_sessions = count;
}

fn statusFlags(state: *const AudioServiceState) u32 {
    var flags = r4os.abi.audio_service_flag_service_ready |
        r4os.abi.audio_service_flag_backend_present |
        r4os.abi.audio_service_flag_mixer_present;
    if (openSessionCount(state) > 0) flags |= r4os.abi.audio_service_flag_sessions_open;
    return flags;
}

fn effectiveVolume(state: *const AudioServiceState, fixed_volume: u32) u32 {
    return scaleVolume(fixed_volume, state.master_volume_fixed);
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
