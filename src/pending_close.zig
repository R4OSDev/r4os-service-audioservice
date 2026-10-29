//! A copied legacy Close request waits in the service loop, never in its
//! dispatcher. The independently progressing backend owns all PCM storage.
const std = @import("std");

pub const Identity = struct {
    client: u32,
    client_generation: u64,
    stream: u32,
    generation: u64,
};
pub const Request = struct {
    owner: Identity,
    request_id: u32,
    started: u64,
    deadline: u64,
};
pub const Reply = struct { request: Request, result: i32 };

pub const Pending = struct {
    request: ?Request = null,

    pub fn begin(self: *Pending, owner: Identity, request_id: u32, started: u64, budget: u64) bool {
        if (self.request != null) return false;
        self.request = .{ .owner = owner, .request_id = request_id, .started = started, .deadline = started +| budget };
        return true;
    }

    pub fn poll(self: *Pending, backend: anytype, now: u64, busy: i32, missing: i32) ?Reply {
        const request = self.request orelse return null;
        const result = if (!backend.matches(request.owner)) missing else if (now >= request.deadline) busy else backend.closeOnce();
        if (result == busy and now < request.deadline) return null;
        self.request = null;
        return .{ .request = request, .result = result };
    }
};

const Fixture = struct {
    owner: Identity = .{ .client = 1, .client_generation = 8, .stream = 3, .generation = 9 },
    calls: usize = 0,
    pcm_consumed: bool = false,
    resource_released: bool = false,
    failure: i32 = 0,
    pub fn matches(self: *@This(), owner: Identity) bool { return std.meta.eql(self.owner, owner); }
    pub fn closeOnce(self: *@This()) i32 {
        self.calls += 1;
        if (self.failure != 0) return self.failure;
        return if (self.pcm_consumed and self.resource_released) 0 else -7;
    }
};

test "legacy reply stays pending until both real PCM and resources finish" {
    var pending: Pending = .{};
    var backend: Fixture = .{};
    try std.testing.expect(pending.begin(backend.owner, 11, 20, 500));
    try std.testing.expect(pending.poll(&backend, 21, -7, -2) == null);
    backend.pcm_consumed = true;
    try std.testing.expect(pending.poll(&backend, 40, -7, -2) == null);
    backend.resource_released = true;
    const reply = pending.poll(&backend, 41, -7, -2).?;
    try std.testing.expectEqual(@as(i32, 0), reply.result);
    try std.testing.expectEqual(@as(u32, 11), reply.request.request_id);
    try std.testing.expectEqual(@as(u64, 20), reply.request.started);
    try std.testing.expect(pending.poll(&backend, 42, -7, -2) == null);
    try std.testing.expectEqual(@as(usize, 3), backend.calls);
}

test "duplicate cannot replace the original response or extend its absolute budget" {
    var pending: Pending = .{};
    var backend: Fixture = .{};
    try std.testing.expect(pending.begin(backend.owner, 11, 20, 500));
    try std.testing.expect(!pending.begin(backend.owner, 12, 519, 500));
    const reply = pending.poll(&backend, 520, -7, -2).?;
    try std.testing.expectEqual(@as(i32, -7), reply.result);
    try std.testing.expectEqual(@as(u32, 11), reply.request.request_id);
    try std.testing.expectEqual(@as(usize, 0), backend.calls);
    try std.testing.expect(!backend.resource_released);
}

test "reused client or stream generation cannot close the new owner" {
    for (0..2) |changed| {
        var pending: Pending = .{};
        var backend: Fixture = .{};
        try std.testing.expect(pending.begin(backend.owner, 11, 20, 500));
        if (changed == 0) backend.owner.client_generation += 1 else backend.owner.generation += 1;
        const reply = pending.poll(&backend, 30, -7, -2).?;
        try std.testing.expectEqual(@as(i32, -2), reply.result);
        try std.testing.expectEqual(@as(usize, 0), backend.calls);
    }
}

test "hard backend failure is returned and does not become an absence receipt" {
    var pending: Pending = .{};
    var backend: Fixture = .{ .failure = -19 };
    try std.testing.expect(pending.begin(backend.owner, 11, 20, 500));
    const reply = pending.poll(&backend, 21, -7, -2).?;
    try std.testing.expectEqual(@as(i32, -19), reply.result);
    try std.testing.expect(!backend.resource_released);
}
