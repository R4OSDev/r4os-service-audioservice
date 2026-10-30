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
    catalog_epoch: abi.AudioOutputCatalog = .{},
    reply: abi.AudioServiceOutputState = .{},

    /// Only the selected, available route from a completed catalog is a
    /// usable backend. A failed refresh retains old catalog data for display,
    /// but cannot confirm its availability. This is not a stream/driver lease.
    pub fn backendPresent(self: *const State) bool {
        return self.active[0] != 0 and
            self.reason != abi.audio_output_reason_api_unavailable and
            self.reason != abi.audio_output_reason_catalog_busy;
    }

    /// A real stream write lost its endpoint. Do not resurrect the previous
    /// positive status from the polling cache; obtain a fresh catalog first.
    pub fn invalidate(self: *State) void {
        self.setActive(null);
        self.setReason(abi.audio_output_reason_catalog_busy);
        self.next_poll = 0;
    }

    pub fn refresh(self: *State, audio: *const r4os.r4audio.Context, now: u64, interval: u64, force: bool) bool {
        if (!force and now < self.next_poll) return true;
        self.next_poll = now +| interval;
        if (!audio.hasFn("audio_output_catalog") or !audio.hasFn("audio_select_output")) {
            self.setReason(abi.audio_output_reason_api_unavailable);
            return false;
        }
        var epoch: abi.AudioOutputCatalog = .{};
        const result = audio.audioOutputCatalog(&self.scratch, &epoch);
        if (result != 1) {
            self.setReason(if (result == abi.err_no_fn or result == abi.err_no_group)
                abi.audio_output_reason_api_unavailable else abi.audio_output_reason_catalog_busy);
            return false;
        }
        if (epoch.version != 1 or epoch.size != @sizeOf(abi.AudioOutputCatalog) or epoch.registry_generation == 0 or
            epoch.count > self.scratch.len or epoch.provider_count > epoch.providers.len) {
            self.setReason(abi.audio_output_reason_catalog_busy);
            return false;
        }
        const count: usize = epoch.count;
        var provider_total: usize = 0;
        for (epoch.providers[0..epoch.provider_count], 0..) |provider, i| {
            if (provider.registration == 0 or provider.generation == 0 or provider.count > 32 or
                provider.active_index < -1 or (provider.active_index >= 0 and @as(u32, @intCast(provider.active_index)) >= provider.count)) {
                self.setReason(abi.audio_output_reason_catalog_busy);
                return false;
            }
            for (epoch.providers[0..i]) |previous| if (previous.registration == provider.registration) {
                self.setReason(abi.audio_output_reason_catalog_busy);
                return false;
            };
            provider_total += provider.count;
        }
        if (provider_total != count) {
            self.setReason(abi.audio_output_reason_catalog_busy);
            return false;
        }
        for (self.scratch[0..count], 0..) |item, index| {
            if (!policy.validId(&item.id) or item.id[0] == 0) {
                self.setReason(abi.audio_output_reason_catalog_busy);
                return false; // Do not publish a partial enumeration.
            }
            for (self.scratch[0..index]) |previous| {
                if (std.mem.eql(u8, &previous.id, &item.id)) {
                    self.setReason(abi.audio_output_reason_catalog_busy);
                    return false;
                }
            }
        }
        if (count != self.count or !std.mem.eql(u8, std.mem.asBytes(&self.catalog_epoch), std.mem.asBytes(&epoch)) or
            !std.mem.eql(u8, std.mem.sliceAsBytes(self.catalog[0..count]), std.mem.sliceAsBytes(self.scratch[0..count]))) self.bump();
        @memcpy(self.catalog[0..count], self.scratch[0..count]);
        self.count = count;
        self.catalog_epoch = epoch;
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
            .hdmi = item.kind == abi.audio_output_kind_hdmi or item.kind == abi.audio_output_kind_display_port,
            .active = item.flags & abi.audio_output_flag_active != 0,
        };
        var selector = Selector{ .owner = self, .audio = audio };
        const resolution = policy.resolve(self.candidates[0..self.count], self.desired, &selector);
        self.setActive(resolution.index);
        self.setReason(switch (resolution.reason) {
            .preferred => abi.audio_output_reason_preferred,
            .auto_hdmi => if (self.catalog[resolution.index.?].kind == abi.audio_output_kind_display_port)
                abi.audio_output_reason_auto_display_port else abi.audio_output_reason_auto_hdmi,
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
