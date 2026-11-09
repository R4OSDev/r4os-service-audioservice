//! One AUDSVC loop owns bounded copied input queues; R4D owns DMA and pins.
const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const capacity: usize = @intCast(a.audio_capture_max_queue_bytes);
const read_bytes: usize = @intCast(a.audio_capture_max_read_bytes);
const Phase = enum { reserved, open, stopping, stopped, closed };
const Slot = struct {
    used: bool = false,
    client: a.ProgramProcessHandle = .{},
    id: a.AudioCaptureHandle = .{},
    source: a.AudioCaptureSourceInfo = .{},
    format: a.AudioCaptureFormat = .{},
    queue_frames: u32 = 0,
    phase: Phase = .closed,
    backend_used: bool = false,
    hardware_stopped: bool = true,
    close_requested: bool = false,
    expires: u64 = 0,
    next_poll: u64 = 0,
    failure: i32 = 0,
    head: usize = 0,
    count: usize = 0,
    first_frame: u64 = 0,
    next_frame: u64 = 0,
    delivered_next: u64 = 0,
    local_drops: u64 = 0,
    backend_drops: u64 = 0,
    timestamp_frame: u64 = 0,
    timestamp: u64 = 0,
    timestamp_valid: bool = false,
    // File-backed, initialized storage. Never lent to DMA or an IRQ producer.
    data: [capacity]u8 = .{0xA5} ** capacity,
};
pub fn sameSource(x: a.AudioCaptureSourceId, y: a.AudioCaptureSourceId) bool {
    return std.meta.eql(x, y);
}
pub fn sameHandle(x: a.AudioCaptureHandle, y: a.AudioCaptureHandle) bool {
    return std.meta.eql(x, y);
}
pub fn validFormat(f: a.AudioCaptureFormat) bool {
    return f.rate_hz > 0 and f.rate_hz <= 192000 and f.channels >= 1 and f.channels <= 8 and f.sample_format == 1 and f.frame_bytes == @as(u32, f.channels) * 2;
}
pub fn validSource(s: a.AudioCaptureSourceInfo) bool {
    const kind = s.flags & (a.audio_capture_source_adc | a.audio_capture_source_controlled);
    if (s.version != 1 or s.size != @sizeOf(a.AudioCaptureSourceInfo) or s.id.registration == 0 or s.id.generation == 0 or s.flags & ~@as(u32, 7) != 0 or (kind != a.audio_capture_source_adc and kind != a.audio_capture_source_controlled) or s.formats != 1 or s.min_rate == 0 or s.min_rate > s.max_rate or s.max_rate > 192000 or s.min_channels == 0 or s.min_channels > s.max_channels or s.max_channels > 8 or s.max_queue_frames == 0) return false;
    const n = std.mem.indexOfScalar(u8, &s.name, 0) orelse s.name.len;
    if (!std.unicode.utf8ValidateSlice(s.name[0..n])) return false;
    if (s.flags & a.audio_capture_source_hardware_timestamp != 0) return s.clock_id > 0 and s.clock_generation > 0 and s.clock_frequency > 0;
    return s.clock_id == 0 and s.clock_generation == 0 and s.clock_frequency == 0;
}
pub fn validReply(r: a.AudioCaptureReply) bool {
    return r.version == 1 and r.size == @sizeOf(a.AudioCaptureReply) and r.reserved == 0 and r.result <= 0 and r.flags & ~@as(u32, 31) == 0 and r.bytes <= read_bytes and (r.result == 0 or (r.bytes == 0 and r.frames == 0));
}
pub const Backend = r4os.audio_capture.Backend;
pub const Manager = struct {
    slots: [4]Slot = .{Slot{}} ** 4,
    scratch: [read_bytes]u8 = .{0xA5} ** read_bytes,
    next_generation: u64 = 1,

    fn call(backend: anytype, request: a.AudioCaptureRequest, reply: *a.AudioCaptureReply, bytes: []u8) i32 {
        var bounded = request;
        bounded.buffer_bytes = if (bounded.op == a.audio_capture_op_read) @intCast(bytes.len) else 0;
        const rc = backend.io(&bounded, reply, bytes);
        if (rc != 0) return if (rc == a.service_api_result_busy) a.audio_capture_error_busy else a.audio_capture_error_unknown_outcome;
        if (!validReply(reply.*)) return a.audio_capture_error_provider;
        return 0;
    }
    fn findSource(self: *Manager, backend: anytype, id: a.AudioCaptureSourceId, out: *a.AudioCaptureSourceInfo) i32 {
        for (0..256) |index| {
            const request: a.AudioCaptureRequest = .{ .op = a.audio_capture_op_catalog, .handle = .{ .source = .{ .source = index } } };
            var reply: a.AudioCaptureReply = .{};
            const rc = call(backend, request, &reply, self.scratch[0..0]);
            if (rc != 0) return rc;
            if (reply.result < 0) return reply.result;
            if (reply.flags & a.audio_capture_reply_source == 0) return a.audio_capture_error_source_gone;
            if (!validSource(reply.source)) return a.audio_capture_error_provider;
            if (sameSource(reply.source.id, id)) {
                out.* = reply.source;
                return 0;
            }
        }
        return a.audio_capture_error_capacity;
    }
    fn snapshot(slot: *const Slot, result: i32) a.AudioCaptureReply {
        return .{ .result = result, .handle = slot.id, .source = slot.source, .format = slot.format, .state = switch (slot.phase) {
            .reserved => a.audio_capture_state_reserved,
            .open => a.audio_capture_state_open,
            .stopping => a.audio_capture_state_stopping,
            .stopped => a.audio_capture_state_stopped,
            .closed => a.audio_capture_state_closed,
        }, .flags = a.audio_capture_reply_source | (if (slot.hardware_stopped) a.audio_capture_reply_hardware_stopped else @as(u32, 0)) | (if (slot.phase == .reserved) a.audio_capture_reply_open_pending else @as(u32, 0)), .queued_frames = if (slot.format.frame_bytes == 0) 0 else @intCast(slot.count / slot.format.frame_bytes), .overrun_frames = slot.local_drops + slot.backend_drops };
    }
    fn makeRequest(slot: *const Slot, op: u32) a.AudioCaptureRequest {
        return .{ .op = op, .handle = slot.id, .format = slot.format, .queue_frames = slot.queue_frames };
    }
    fn activate(self: *Manager, slot: *Slot, backend: anytype) i32 {
        if (slot.phase != .reserved) return if (slot.phase == .open) 0 else a.audio_capture_error_stale;
        slot.backend_used = true;
        slot.hardware_stopped = false;
        var reply: a.AudioCaptureReply = .{};
        const rc = call(backend, makeRequest(slot, a.audio_capture_op_open), &reply, self.scratch[0..0]);
        if (rc != 0) {
            slot.phase = .stopping;
            slot.failure = rc;
            return rc;
        }
        if (!sameHandle(reply.handle, slot.id)) {
            slot.phase = .stopping;
            slot.failure = a.audio_capture_error_provider;
            return slot.failure;
        }
        if (reply.result < 0) {
            slot.phase = .stopping;
            slot.failure = reply.result;
            slot.hardware_stopped = reply.flags & a.audio_capture_reply_hardware_stopped != 0;
            return reply.result;
        }
        if (!std.meta.eql(reply.format, slot.format)) {
            slot.phase = .stopping;
            slot.failure = a.audio_capture_error_provider;
            return slot.failure;
        }
        slot.phase = .open;
        return 0;
    }
    fn stopSlot(self: *Manager, slot: *Slot, backend: anytype) i32 {
        if (slot.hardware_stopped) {
            slot.phase = .stopped;
            return 0;
        }
        slot.phase = .stopping;
        var reply: a.AudioCaptureReply = .{};
        const rc = call(backend, makeRequest(slot, a.audio_capture_op_stop), &reply, self.scratch[0..0]);
        if (rc != 0) return rc;
        if (!sameHandle(reply.handle, slot.id)) return a.audio_capture_error_provider;
        if (reply.flags & a.audio_capture_reply_hardware_stopped == 0) return if (reply.result < 0) reply.result else a.audio_capture_error_busy;
        if (reply.result != 0 and reply.result != a.audio_capture_error_source_gone) return reply.result;
        slot.hardware_stopped = true;
        slot.phase = .stopped;
        return 0;
    }
    fn closeSlot(self: *Manager, slot: *Slot, backend: anytype) i32 {
        if (!slot.used) return 0;
        slot.close_requested = true;
        const stopped = self.stopSlot(slot, backend);
        if (stopped != 0) return stopped;
        if (slot.backend_used) {
            var reply: a.AudioCaptureReply = .{};
            const rc = call(backend, makeRequest(slot, a.audio_capture_op_close), &reply, self.scratch[0..0]);
            if (rc != 0) return rc;
            if (!sameHandle(reply.handle, slot.id)) return a.audio_capture_error_provider;
            if (reply.flags & a.audio_capture_reply_hardware_stopped == 0 or (reply.result != 0 and reply.result != a.audio_capture_error_source_gone)) return if (reply.result < 0) reply.result else a.audio_capture_error_busy;
        }
        slot.backend_used = false;
        slot.hardware_stopped = true;
        slot.used = false;
        slot.phase = .closed;
        slot.count = 0;
        return 0;
    }
    fn lose(slot: *Slot, code: i32) i32 {
        slot.phase = .stopping;
        slot.failure = code;
        return code;
    }
    fn append(self: *Manager, slot: *Slot, incoming: a.AudioCaptureReply) i32 {
        if (incoming.flags & a.audio_capture_reply_hardware_timestamp != 0 and (slot.source.flags & a.audio_capture_source_hardware_timestamp == 0 or incoming.flags & a.audio_capture_reply_source == 0)) return lose(slot, a.audio_capture_error_provider);
        if (!sameHandle(incoming.handle, slot.id) or !std.meta.eql(incoming.format, slot.format) or incoming.frames == 0 or incoming.bytes != @as(u64, incoming.frames) * slot.format.frame_bytes or incoming.first_frame < slot.next_frame or incoming.overrun_frames < slot.backend_drops) return lose(slot, a.audio_capture_error_provider);
        if (incoming.flags & a.audio_capture_reply_source != 0 and (!sameSource(incoming.source.id, slot.source.id) or incoming.source.clock_id != slot.source.clock_id or incoming.source.clock_generation != slot.source.clock_generation or incoming.source.clock_frequency != slot.source.clock_frequency)) return lose(slot, a.audio_capture_error_clock_changed);
        const end = std.math.add(u64, incoming.first_frame, incoming.frames) catch return lose(slot, a.audio_capture_error_exhausted);
        const width: usize = slot.format.frame_bytes;
        const limit: usize = @as(usize, slot.queue_frames) * width;
        var dropped: u64 = 0;
        if (incoming.first_frame != slot.next_frame) {
            dropped = slot.count / width;
            slot.count = 0;
            slot.head = 0;
            slot.timestamp_valid = false;
        }
        const skip = if (incoming.bytes > limit) incoming.bytes - limit else 0;
        const keep: usize = incoming.bytes - skip;
        if (slot.count + keep > limit) {
            const n = slot.count + keep - limit;
            slot.head = (slot.head + n) % limit;
            slot.count -= n;
            slot.first_frame += n / width;
            dropped += n / width;
            slot.timestamp_valid = false;
        }
        dropped += skip / width;
        const local = std.math.add(u64, slot.local_drops, dropped) catch return lose(slot, a.audio_capture_error_exhausted);
        _ = std.math.add(u64, local, incoming.overrun_frames) catch return lose(slot, a.audio_capture_error_exhausted);
        if (slot.count == 0) {
            slot.first_frame = incoming.first_frame + skip / width;
            slot.timestamp_valid = incoming.flags & a.audio_capture_reply_hardware_timestamp != 0 and skip == 0;
            slot.timestamp_frame = slot.first_frame;
            slot.timestamp = if (slot.timestamp_valid) incoming.first_timestamp else 0;
        }
        const tail = (slot.head + slot.count) % limit;
        const first = @min(keep, limit - tail);
        @memcpy(slot.data[tail..][0..first], self.scratch[skip..][0..first]);
        @memcpy(slot.data[0 .. keep - first], self.scratch[skip + first ..][0 .. keep - first]);
        slot.count += keep;
        slot.next_frame = end;
        slot.local_drops = local;
        slot.backend_drops = incoming.overrun_frames;
        return 0;
    }
    fn pump(self: *Manager, slot: *Slot, backend: anytype) i32 {
        if (slot.phase != .open) return 0;
        var q = makeRequest(slot, a.audio_capture_op_read);
        q.frames = @intCast(read_bytes / slot.format.frame_bytes);
        var reply: a.AudioCaptureReply = .{};
        const rc = call(backend, q, &reply, &self.scratch);
        if (rc != 0) return lose(slot, rc);
        if (!sameHandle(reply.handle, slot.id)) return lose(slot, a.audio_capture_error_provider);
        if (reply.result == a.audio_capture_error_would_block) return 0;
        if (reply.result < 0) return lose(slot, reply.result);
        if (reply.bytes == 0) return if (reply.frames == 0 and reply.state == a.audio_capture_state_stopped and reply.flags & a.audio_capture_reply_hardware_stopped != 0) blk: {
            slot.phase = .stopped;
            slot.hardware_stopped = true;
            break :blk 0;
        } else lose(slot, a.audio_capture_error_provider);
        return self.append(slot, reply);
    }
    /// Caller supplies the full current service/client handles and disjoint
    /// output storage. This manager runs only on AUDSVC's original loop thread.
    pub fn handle(self: *Manager, service: a.ProgramProcessHandle, client: a.ProgramProcessHandle, q: a.AudioCaptureRequest, bytes: []u8, now: u64, hz: u64, backend: anytype) a.AudioCaptureReply {
        if (q.version != 1 or q.size != @sizeOf(a.AudioCaptureRequest) or q.flags != 0 or q.buffer_bytes > read_bytes or (q.op != a.audio_capture_op_read and q.buffer_bytes != 0) or q.op > 5 or service.instance_id == 0 or service.generation == 0 or client.instance_id == 0 or client.generation == 0 or q.client_generation != client.generation or hz == 0 or bytes.len > read_bytes) return .{ .result = a.audio_capture_error_invalid };
        if (q.op == a.audio_capture_op_catalog) {
            if (q.handle.source.registration != 0 or q.handle.source.generation != 0) return .{ .result = a.audio_capture_error_invalid };
            var reply: a.AudioCaptureReply = .{};
            const rc = call(backend, q, &reply, self.scratch[0..0]);
            if (rc != 0) return .{ .result = rc };
            if (reply.flags & a.audio_capture_reply_source != 0 and !validSource(reply.source)) return .{ .result = a.audio_capture_error_provider };
            reply.handle.service = service;
            return reply;
        }
        if (q.op == a.audio_capture_op_open) {
            if (!validFormat(q.format) or q.queue_frames == 0 or @as(u64, q.queue_frames) * q.format.frame_bytes > capacity) return .{ .result = a.audio_capture_error_format };
            var source: a.AudioCaptureSourceInfo = .{};
            const rc = self.findSource(backend, q.handle.source, &source);
            if (rc != 0) return .{ .result = rc };
            if (q.format.rate_hz < source.min_rate or q.format.rate_hz > source.max_rate or q.format.channels < source.min_channels or q.format.channels > source.max_channels or q.queue_frames > source.max_queue_frames) return .{ .result = a.audio_capture_error_format };
            if (self.next_generation == std.math.maxInt(u64)) return .{ .result = a.audio_capture_error_exhausted };
            const expires = std.math.add(u64, now, std.math.mul(u64, hz, 5) catch return .{ .result = a.audio_capture_error_exhausted }) catch return .{ .result = a.audio_capture_error_exhausted };
            for (&self.slots, 0..) |*s, index| if (!s.used) {
                // Reset metadata only: queue bytes are already fully initialized.
                s.used = true;
                s.client = client;
                s.id = .{ .service = service, .source = source.id, .stream = index + 1, .generation = self.next_generation };
                self.next_generation += 1;
                s.source = source;
                s.format = q.format;
                s.queue_frames = q.queue_frames;
                s.phase = .reserved;
                s.backend_used = false;
                s.hardware_stopped = true;
                s.close_requested = false;
                s.expires = expires;
                s.next_poll = now;
                s.failure = 0;
                s.head = 0;
                s.count = 0;
                s.first_frame = 0;
                s.next_frame = 0;
                s.delivered_next = 0;
                s.local_drops = 0;
                s.backend_drops = 0;
                s.timestamp_valid = false;
                return snapshot(s, 0);
            };
            return .{ .result = a.audio_capture_error_capacity };
        }
        if (!std.meta.eql(q.handle.service, service)) return .{ .result = a.audio_capture_error_stale };
        const s = blk: {
            for (&self.slots) |*s| if (std.meta.eql(s.client, client) and sameHandle(s.id, q.handle)) break :blk s;
            return .{ .result = a.audio_capture_error_stale };
        };
        if (!s.used) return snapshot(s, if (q.op == a.audio_capture_op_close or q.op == a.audio_capture_op_query) 0 else a.audio_capture_error_stale);
        if (s.phase == .reserved and !s.backend_used and now >= s.expires) {
            _ = self.closeSlot(s, backend);
            return snapshot(s, if (q.op == a.audio_capture_op_close) 0 else a.audio_capture_error_stale);
        }
        if (q.op == a.audio_capture_op_query) return snapshot(s, s.failure);
        if (q.op == a.audio_capture_op_stop) return snapshot(s, self.stopSlot(s, backend));
        if (q.op == a.audio_capture_op_close) return snapshot(s, self.closeSlot(s, backend));
        if (q.frames == 0 or @as(u64, q.frames) * s.format.frame_bytes > bytes.len or @as(u64, q.frames) * s.format.frame_bytes > q.buffer_bytes) return snapshot(s, a.audio_capture_error_capacity);
        // A physical Stop ACK after failure does not turn source loss into EOF.
        if (s.failure != 0) return snapshot(s, s.failure);
        if (s.phase == .reserved) {
            const rc = self.activate(s, backend);
            if (rc != 0) return snapshot(s, rc);
        }
        if (s.phase == .stopping) return snapshot(s, if (s.failure != 0) s.failure else a.audio_capture_error_busy);
        const rc = self.pump(s, backend);
        if (rc != 0) return snapshot(s, rc);
        if (s.count == 0) return snapshot(s, if (s.phase == .stopped) 0 else a.audio_capture_error_would_block);
        const width: usize = s.format.frame_bytes;
        const count = @min(@as(usize, q.frames) * width, s.count);
        const limit = @as(usize, s.queue_frames) * width;
        if (s.first_frame < s.delivered_next) return snapshot(s, lose(s, a.audio_capture_error_provider));
        var reply = snapshot(s, 0);
        reply.first_frame = s.first_frame;
        reply.gap_frames = s.first_frame - s.delivered_next;
        if (reply.gap_frames > 0) reply.flags |= a.audio_capture_reply_discontinuity;
        if (s.timestamp_valid and s.timestamp_frame == s.first_frame) {
            reply.flags |= a.audio_capture_reply_hardware_timestamp;
            reply.first_timestamp = s.timestamp;
        }
        reply.bytes = @intCast(count);
        reply.frames = @intCast(count / width);
        const first = @min(count, limit - s.head);
        @memcpy(bytes[0..first], s.data[s.head..][0..first]);
        @memcpy(bytes[first..count], s.data[0 .. count - first]);
        s.head = (s.head + count) % limit;
        s.count -= count;
        s.first_frame += reply.frames;
        s.delivered_next = s.first_frame;
        s.timestamp_valid = false;
        reply.queued_frames = @intCast(s.count / width);
        return reply;
    }
    pub fn maintenance(self: *Manager, now: u64, interval: u64, backend: anytype) void {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (s.phase == .reserved and !s.backend_used and now >= s.expires) {
                _ = self.closeSlot(s, backend);
                continue;
            }
            if (now < s.next_poll) continue;
            s.next_poll = now +| @max(interval, 1);
            if (s.close_requested) {
                _ = self.closeSlot(s, backend);
            } else if (s.phase == .stopping) {
                _ = self.stopSlot(s, backend);
            } else if (s.phase == .open) {
                _ = self.pump(s, backend);
            }
        }
    }
    pub fn deadline(self: *const Manager, current: ?u64) ?u64 {
        var next = current;
        for (&self.slots) |*s| if (s.used and (s.phase != .stopped or s.close_requested)) {
            const tick = if (s.phase == .reserved and !s.backend_used) s.expires else s.next_poll;
            if (next == null or tick < next.?) next = tick;
        };
        return next;
    }
    pub fn any(self: *const Manager) bool {
        for (&self.slots) |*s| if (s.used) return true;
        return false;
    }
    pub fn stopAll(self: *Manager, backend: anytype) bool {
        var done = true;
        for (&self.slots) |*s| if (s.used) {
            _ = self.closeSlot(s, backend);
            done = done and !s.used;
        };
        return done;
    }
    pub fn reap(self: *Manager, backend: anytype, reader: anytype) void {
        const ownership = @import("session_ownership.zig");
        var owners: [4]ownership.Owner = undefined;
        var live: [4]u64 = undefined;
        var indices: [4]usize = undefined;
        var count: usize = 0;
        for (&self.slots, 0..) |*s, i| if (s.used) {
            owners[count] = .{ .id = s.client.instance_id, .generation = s.client.generation };
            indices[count] = i;
            count += 1;
        };
        if (count == 0 or !ownership.collectRunning(owners[0..count], live[0..count], reader)) return;
        for (indices[0..count], live[0..count]) |i, generation| if (generation == 0) {
            _ = self.closeSlot(&self.slots[i], backend);
        };
    }
};
