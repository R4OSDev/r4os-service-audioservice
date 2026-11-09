const std = @import("std");
const r4os = @import("r4os");
const a = r4os.abi;
const c = @import("capture.zig");
const service: a.ProgramProcessHandle = .{ .instance_id = 7, .generation = 70 };
const client: a.ProgramProcessHandle = .{ .instance_id = 8, .generation = 80 };
const format: a.AudioCaptureFormat = .{ .rate_hz = 48000, .channels = 2, .sample_format = 1, .frame_bytes = 4 };
const Backend = struct {
    enabled: bool = true,
    source_generation: u64 = 1,
    clock_generation: u64 = 1,
    hardware_timestamp: bool = false,
    held: bool = false,
    stopped: bool = false,
    would_block: bool = false,
    bad_frame: bool = false,
    opens: usize = 0,
    reads: usize = 0,
    stops: usize = 0,
    closes: usize = 0,
    stop_busy: u32 = 0,
    close_busy: u32 = 0,
    next_frame: u64 = 0,
    frames: u32 = 4,
    id: a.AudioCaptureHandle = .{},
    pcm: a.AudioCaptureFormat = .{},
    fn source(self: *const Backend) a.AudioCaptureSourceInfo {
        return .{ .id = .{ .registration = 7, .source = 0, .generation = self.source_generation }, .flags = a.audio_capture_source_controlled | (if (self.hardware_timestamp) a.audio_capture_source_hardware_timestamp else @as(u32, 0)), .formats = 1, .min_rate = 8000, .max_rate = 192000, .min_channels = 1, .max_channels = 8, .max_queue_frames = 4096, .clock_id = if (self.hardware_timestamp) 1 else 0, .clock_generation = if (self.hardware_timestamp) self.clock_generation else 0, .clock_frequency = if (self.hardware_timestamp) 48000 else 0 };
    }
    pub fn io(self: *Backend, q: *const a.AudioCaptureRequest, r: *a.AudioCaptureReply, bytes: []u8) i32 {
        r.* = .{ .handle = q.handle, .source = self.source(), .flags = a.audio_capture_reply_source, .format = self.pcm, .state = if (self.stopped) a.audio_capture_state_stopped else a.audio_capture_state_open };
        if (q.op == a.audio_capture_op_catalog) {
            if (!self.enabled) {
                r.result = a.audio_capture_error_unsupported;
                r.flags = 0;
            } else if (q.handle.source.source != 0) {
                r.flags = 0;
            }
            return 0;
        }
        if (q.op == a.audio_capture_op_open) {
            self.opens += 1;
            self.id = q.handle;
            self.pcm = q.format;
            self.next_frame = 0;
            self.held = true;
            self.stopped = false;
            r.format = self.pcm;
            return 0;
        }
        if (!c.sameHandle(q.handle, self.id)) {
            r.result = a.audio_capture_error_stale;
            return 0;
        }
        if (q.op == a.audio_capture_op_read) {
            self.reads += 1;
            if (q.handle.source.generation != self.source_generation) {
                r.result = a.audio_capture_error_source_gone;
                return 0;
            }
            if (self.would_block) {
                r.result = a.audio_capture_error_would_block;
                return 0;
            }
            if (self.stopped) {
                r.flags |= a.audio_capture_reply_hardware_stopped;
                return 0;
            }
            const count = @min(q.frames, self.frames);
            const len = count * self.pcm.frame_bytes;
            std.debug.assert(len <= bytes.len);
            for (bytes[0..len], 0..) |*b, i| b.* = @truncate(self.next_frame + i / self.pcm.frame_bytes);
            r.frames = count;
            r.bytes = if (self.bad_frame) len - 1 else len;
            r.first_frame = self.next_frame;
            self.next_frame += count;
            if (self.hardware_timestamp) {
                r.flags |= a.audio_capture_reply_hardware_timestamp;
                r.first_timestamp = 100 + r.first_frame;
            }
            return 0;
        }
        if (q.op == a.audio_capture_op_query) {
            if (self.stopped) r.flags |= a.audio_capture_reply_hardware_stopped;
            return 0;
        }
        if (q.op == a.audio_capture_op_stop) {
            self.stops += 1;
            if (self.stop_busy > 0) {
                self.stop_busy -= 1;
                r.result = a.audio_capture_error_busy;
                return 0;
            }
            self.stopped = true;
            r.flags |= a.audio_capture_reply_hardware_stopped;
            r.state = a.audio_capture_state_stopped;
            return 0;
        }
        if (q.op == a.audio_capture_op_close) {
            self.closes += 1;
            if (!self.stopped or self.close_busy > 0) {
                if (self.close_busy > 0) self.close_busy -= 1;
                r.result = a.audio_capture_error_busy;
                return 0;
            }
            self.held = false;
            r.flags |= a.audio_capture_reply_hardware_stopped;
            r.state = a.audio_capture_state_closed;
            return 0;
        }
        return -1;
    }
};
fn reserve(m: *c.Manager, b: *Backend, frames: u32) a.AudioCaptureReply {
    return m.handle(service, client, .{ .op = a.audio_capture_op_open, .client_generation = client.generation, .handle = .{ .source = b.source().id }, .format = format, .queue_frames = frames }, &.{}, 0, 1000, b);
}
fn operation(m: *c.Manager, b: *Backend, id: a.AudioCaptureHandle, op: u32, frames: u32, bytes: []u8) a.AudioCaptureReply {
    return m.handle(service, client, .{ .op = op, .client_generation = client.generation, .handle = id, .frames = frames, .buffer_bytes = if (op == a.audio_capture_op_read) @intCast(bytes.len) else 0 }, bytes, 1, 1000, b);
}
test "capture availability and reservation expire without fabricated input or DMA" {
    var m: c.Manager = .{};
    var b: Backend = .{ .enabled = false };
    var r = m.handle(service, client, .{ .client_generation = client.generation }, &.{}, 0, 1000, &b);
    try std.testing.expectEqual(a.audio_capture_error_unsupported, r.result);
    try std.testing.expectEqual(@as(u32, 0), r.flags);
    try std.testing.expectEqual(a.audio_capture_error_unsupported, reserve(&m, &b, 4).result);
    try std.testing.expect(!m.any() and !b.held and b.opens == 0);
    b.enabled = true;
    r = reserve(&m, &b, 4);
    try std.testing.expectEqual(@as(i32, 0), r.result);
    try std.testing.expect(r.state == a.audio_capture_state_reserved and b.opens == 0 and !b.held);
    var out: [16]u8 = .{0xA5} ** 16;
    const expired = m.handle(service, client, .{ .op = a.audio_capture_op_read, .client_generation = client.generation, .handle = r.handle, .frames = 4, .buffer_bytes = out.len }, &out, 5000, 1000, &b);
    try std.testing.expectEqual(a.audio_capture_error_stale, expired.result);
    try std.testing.expect(!m.any() and b.opens == 0 and !b.held);
    try std.testing.expectEqualSlices(u8, &(.{0xA5} ** 16), &out);
}
test "capture original queue copies whole FIFO frames and reports exact bounded overrun gap" {
    var m: c.Manager = .{};
    var b: Backend = .{};
    const id = reserve(&m, &b, 4).handle;
    var out: [16]u8 = .{0xA5} ** 16;
    var r = operation(&m, &b, id, a.audio_capture_op_read, 2, &out);
    try std.testing.expect(r.result == 0 and r.frames == 2 and r.first_frame == 0 and r.gap_frames == 0 and b.opens == 1 and b.held);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 1, 1, 1, 1 }, out[0..8]);
    try std.testing.expect(out[8] == 0xA5);
    b.would_block = true;
    r = operation(&m, &b, id, a.audio_capture_op_read, 2, &out);
    try std.testing.expect(r.result == 0 and r.first_frame == 2 and r.gap_frames == 0);
    try std.testing.expectEqualSlices(u8, &.{ 2, 2, 2, 2, 3, 3, 3, 3 }, out[0..8]);
    b.would_block = false;
    m.maintenance(2, 1, &b);
    m.maintenance(3, 1, &b);
    b.would_block = true;
    r = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    try std.testing.expect(r.result == 0 and r.first_frame == 8 and r.frames == 4 and r.gap_frames == 4 and r.overrun_frames == 4 and r.flags & a.audio_capture_reply_discontinuity != 0);
    try std.testing.expectEqualSlices(u8, &.{ 8, 8, 8, 8, 9, 9, 9, 9, 10, 10, 10, 10, 11, 11, 11, 11 }, &out);
    try std.testing.expect(r.first_timestamp == 0 and r.flags & a.audio_capture_reply_hardware_timestamp == 0);
    try std.testing.expect(m.stopAll(&b));
}
test "capture Stop and Close retain exact queue and backend until separate physical ACKs" {
    var m: c.Manager = .{};
    var b: Backend = .{ .stop_busy = 1, .close_busy = 1 };
    const id = reserve(&m, &b, 4).handle;
    var out: [16]u8 = undefined;
    _ = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    var r = operation(&m, &b, id, a.audio_capture_op_close, 0, &.{});
    try std.testing.expect(r.result == a.audio_capture_error_busy and m.any() and b.held and !b.stopped and b.closes == 0);
    r = operation(&m, &b, id, a.audio_capture_op_close, 0, &.{});
    try std.testing.expect(r.result == a.audio_capture_error_busy and m.any() and b.held and b.stopped and b.closes == 1);
    r = operation(&m, &b, id, a.audio_capture_op_close, 0, &.{});
    try std.testing.expect(r.result == 0 and !m.any() and !b.held and b.closes == 2);
    const fresh = reserve(&m, &b, 4).handle;
    try std.testing.expect(fresh.stream == id.stream and fresh.generation > id.generation);
    r = operation(&m, &b, id, a.audio_capture_op_close, 0, &.{});
    try std.testing.expectEqual(a.audio_capture_error_stale, r.result);
    try std.testing.expect(m.any());
    try std.testing.expect(m.stopAll(&b));
}
test "capture source loss clock change and malformed frames publish no new bytes or resource release" {
    var m: c.Manager = .{};
    var b: Backend = .{};
    var id = reserve(&m, &b, 4).handle;
    var out: [16]u8 = .{0xA5} ** 16;
    _ = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    b.source_generation += 1;
    @memset(&out, 0xA5);
    var r = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    try std.testing.expect(r.result == a.audio_capture_error_source_gone and b.held and m.any());
    try std.testing.expectEqualSlices(u8, &(.{0xA5} ** 16), &out);
    m.maintenance(2, 1, &b);
    r = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    try std.testing.expect(r.result == a.audio_capture_error_source_gone and b.stopped and b.held);
    try std.testing.expectEqualSlices(u8, &(.{0xA5} ** 16), &out);
    try std.testing.expect(m.stopAll(&b));
    b = .{};
    b.hardware_timestamp = true;
    id = reserve(&m, &b, 4).handle;
    r = operation(&m, &b, id, a.audio_capture_op_read, 2, &out);
    try std.testing.expect(r.result == 0 and r.first_timestamp == 100 and r.flags & a.audio_capture_reply_hardware_timestamp != 0);
    b.would_block = true;
    r = operation(&m, &b, id, a.audio_capture_op_read, 2, &out);
    try std.testing.expect(r.result == 0 and r.first_timestamp == 0 and r.flags & a.audio_capture_reply_hardware_timestamp == 0);
    b.would_block = false;
    b.clock_generation += 1;
    @memset(&out, 0xA5);
    r = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    try std.testing.expect(r.result == a.audio_capture_error_clock_changed and m.any() and b.held);
    try std.testing.expectEqualSlices(u8, &(.{0xA5} ** 16), &out);
    try std.testing.expect(m.stopAll(&b));
    b = .{};
    b.bad_frame = true;
    id = reserve(&m, &b, 4).handle;
    r = operation(&m, &b, id, a.audio_capture_op_read, 4, &out);
    try std.testing.expect(r.result == a.audio_capture_error_provider and m.any() and b.held);
    try std.testing.expect(m.stopAll(&b));
}
test "capture capacity caller generation and exhausted IDs reject before side effects" {
    var m: c.Manager = .{};
    var b: Backend = .{};
    const id = reserve(&m, &b, 4).handle;
    var small: [7]u8 = .{0xA5} ** 7;
    const r = operation(&m, &b, id, a.audio_capture_op_read, 2, &small);
    try std.testing.expectEqual(a.audio_capture_error_capacity, r.result);
    try std.testing.expect(b.opens == 0 and !b.held);
    // Real RPC handlers have a larger staging buffer than the caller. The
    // wire capacity must still reject before activation/dequeue.
    var staging: [2048]u8 = @splat(0xA5);
    const wire = m.handle(service, client, .{ .op = a.audio_capture_op_read, .client_generation = client.generation, .handle = id, .frames = 2, .buffer_bytes = 7 }, &staging, 1, 1000, &b);
    try std.testing.expectEqual(a.audio_capture_error_capacity, wire.result);
    try std.testing.expect(b.opens == 0 and b.reads == 0 and !b.held);
    try std.testing.expectEqualSlices(u8, &(.{0xA5} ** 2048), &staging);
    try std.testing.expect(m.stopAll(&b));
    const wrong = m.handle(service, client, .{ .op = a.audio_capture_op_open, .client_generation = client.generation + 1, .handle = .{ .source = b.source().id }, .format = format, .queue_frames = 4 }, &.{}, 0, 1000, &b);
    try std.testing.expectEqual(a.audio_capture_error_invalid, wrong.result);
    try std.testing.expect(!m.any());
    for (0..4) |_| try std.testing.expectEqual(@as(i32, 0), reserve(&m, &b, 4).result);
    try std.testing.expectEqual(a.audio_capture_error_capacity, reserve(&m, &b, 4).result);
    try std.testing.expect(b.opens == 0);
    try std.testing.expect(m.stopAll(&b));
    m.next_generation = std.math.maxInt(u64);
    try std.testing.expectEqual(a.audio_capture_error_exhausted, reserve(&m, &b, 4).result);
    try std.testing.expect(!m.any());
}
