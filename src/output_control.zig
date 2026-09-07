const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const policy = @import("output_policy.zig");

pub const State = struct {
    desired: policy.Id = policy.automatic,
    active: policy.Id = policy.automatic,
    active_name: [64]u8 = .{0} ** 64,
    revision: u64 = 1,
    reason: u32 = abi.audio_output_reason_none_available,
    next_poll: u64 = 0,
    count: usize = 0,
    catalog: [policy.capacity]abi.AudioOutputInfo = .{abi.AudioOutputInfo{}} ** policy.capacity,
    scratch: [policy.capacity]abi.AudioOutputInfo = .{abi.AudioOutputInfo{}} ** policy.capacity,
    candidates: [policy.capacity]policy.Candidate = undefined,
    reply: abi.AudioServiceOutputState = .{},

    pub fn refresh(self: *State, audio: *const r4os.r4audio.Context, now: u64, interval: u64, force: bool) bool {
        if (!force and now < self.next_poll) return true;
        self.next_poll = now +| interval;
        if (!audio.hasFn("audio_output_info") or !audio.hasFn("audio_select_output")) {
            self.setReason(abi.audio_output_reason_api_unavailable);
            return false;
        }
        var count: usize = 0;
        while (count < self.scratch.len) : (count += 1) {
            const result = audio.audioOutputInfo(@intCast(count), &self.scratch[count]);
            if (result == 0) break;
            if (result != 1 or !policy.validId(&self.scratch[count].id) or self.scratch[count].id[0] == 0) {
                self.setReason(abi.audio_output_reason_catalog_busy);
                return false; // Do not publish a partial enumeration.
            }
            for (self.scratch[0..count]) |previous| {
                if (std.mem.eql(u8, &previous.id, &self.scratch[count].id)) {
                    self.setReason(abi.audio_output_reason_catalog_busy);
                    return false;
                }
            }
        }
        if (count != self.count or !std.mem.eql(u8, std.mem.sliceAsBytes(self.catalog[0..count]), std.mem.sliceAsBytes(self.scratch[0..count]))) self.bump();
        @memcpy(self.catalog[0..count], self.scratch[0..count]);
        self.count = count;
        self.resolve(audio);
        return true;
    }

    pub fn select(self: *State, audio: *const r4os.r4audio.Context, id: policy.Id) i32 {
        if (!policy.validId(&id)) return abi.service_api_result_invalid;
        if (id[0] != 0) {
            var found: ?usize = null;
            for (self.catalog[0..self.count], 0..) |item, i| {
                if (std.mem.eql(u8, &id, &item.id) and item.availability == abi.audio_output_available) {
                    found = i;
                    break;
                }
            }
            const index = found orelse return abi.service_api_result_no_endpoint;
            const result = audio.audioSelectOutput(&id);
            if (result < 0) {
                self.setReason(abi.audio_output_reason_activation_failed);
                return result;
            }
            self.setActive(index);
        }
        if (!std.mem.eql(u8, &self.desired, &id)) {
            self.desired = id;
            self.bump();
        }
        self.resolve(audio);
        return 0;
    }

    pub fn page(self: *State, index: u32, epoch: u64, flags: u32) *const abi.AudioServiceOutputState {
        self.reply = .{ .service_epoch = epoch, .revision = self.revision, .total = @intCast(self.count), .index = index, .reason = self.reason, .flags = flags, .desired_id = self.desired, .active_id = self.active, .active_name = self.active_name };
        if (index < self.count) {
            const count = @min(self.reply.outputs.len, self.count - index);
            self.reply.count = @intCast(count);
            @memcpy(self.reply.outputs[0..count], self.catalog[index..][0..count]);
        }
        return &self.reply;
    }

    fn resolve(self: *State, audio: *const r4os.r4audio.Context) void {
        for (self.catalog[0..self.count], 0..) |item, i| self.candidates[i] = .{
            .id = item.id,
            .available = item.availability == abi.audio_output_available,
            .hdmi = item.kind == abi.audio_output_kind_hdmi,
            .active = item.flags & abi.audio_output_flag_active != 0,
        };
        var selector = Selector{ .owner = self, .audio = audio };
        const resolution = policy.resolve(self.candidates[0..self.count], self.desired, &selector);
        self.setActive(resolution.index);
        self.setReason(switch (resolution.reason) {
            .preferred => abi.audio_output_reason_preferred,
            .auto_hdmi => abi.audio_output_reason_auto_hdmi,
            .auto_analog => abi.audio_output_reason_auto_analog,
            .preferred_unavailable => abi.audio_output_reason_preferred_unavailable,
            .none_available => abi.audio_output_reason_none_available,
            .activation_failed => abi.audio_output_reason_activation_failed,
        });
    }

    fn setActive(self: *State, index: ?usize) void {
        const active = if (index) |i| self.catalog[i].id else policy.automatic;
        if (!std.mem.eql(u8, &self.active, &active)) self.bump();
        self.active = active;
        self.active_name = if (index) |i| self.catalog[i].name else .{0} ** 64;
        for (self.catalog[0..self.count], 0..) |*item, i| {
            item.flags &= ~abi.audio_output_flag_active;
            if (index == i) item.flags |= abi.audio_output_flag_active;
        }
    }

    fn setReason(self: *State, reason: u32) void {
        if (self.reason != reason) {
            self.reason = reason;
            self.bump();
        }
    }

    fn bump(self: *State) void {
        self.revision +%= 1;
        if (self.revision == 0) self.revision = 1;
    }

    const Selector = struct {
        owner: *State,
        audio: *const r4os.r4audio.Context,
        pub fn activate(self: *Selector, index: usize) bool {
            return self.audio.audioSelectOutput(&self.owner.catalog[index].id) == 0;
        }
    };
};
