//! One copied operation; only a successful exact-generation Join retires it.
const r4os = @import("r4os");
const a = r4os.abi;
const control = @import("output_control.zig");

pub const Request = struct {
    client_id: u32,
    client_generation: u64,
    request_id: u32,
    started: u64,
};
pub const Completion = struct {
    service_epoch: u64,
    request: ?Request,
    operation: control.Operation,
    outcome: control.Outcome,
};
pub const Poll = union(enum) { idle, pending, fault: i32, completed: Completion };

pub const Job = struct {
    in_flight: bool = false,
    handle: a.ProgramJoinHandle = .{},
    service_epoch: u64 = 0,
    request: ?Request = null,
    audio: r4os.r4audio.Context = undefined,
    operation: control.Operation = .{},
    outcome: control.Outcome = .{},

    pub fn start(self: *Job, sys: *const r4os.r4sys.Context, audio: r4os.r4audio.Context, epoch: u64, operation: control.Operation, request: ?Request) i32 {
        if (self.in_flight) return a.service_api_result_busy;
        if (epoch == 0 or operation.count == 0) return a.service_api_result_invalid;
        if (!sys.hasFn("thread_create_handle") or !sys.hasFn("thread_handle_join")) return a.err_no_fn;
        // Immutable while the thread exists. Neither callback nor driver gets
        // a pointer into the dispatcher's state, catalog, payload or reply.
        self.service_epoch = epoch;
        self.request = request;
        self.audio = audio;
        self.operation = operation;
        self.outcome = .{};
        self.handle = .{};
        const result = sys.threadCreateHandle(worker, @intFromPtr(self), 0, 0, &self.handle);
        if (result != a.thread_ok) return result;
        self.in_flight = true;
        return 0;
    }

    pub fn poll(self: *Job, sys: *const r4os.r4sys.Context, timeout_ticks: u64) Poll {
        if (!self.in_flight) return .idle;
        var exit: i32 = -1;
        const result = sys.threadHandleJoin(&self.handle, timeout_ticks, &exit);
        if (result == a.thread_error_timeout or result == a.thread_error_busy) return .pending;
        // An arbitrary error is not a terminal/thread/storage receipt. Keep
        // the immutable arguments and the exact handle until Join succeeds.
        if (result != a.thread_ok) return .{ .fault = result };
        const completed: Completion = .{
            .service_epoch = self.service_epoch,
            .request = self.request,
            .operation = self.operation,
            .outcome = if (exit == 0) self.outcome else .{ .result = a.service_api_result_invalid, .resolution = self.operation.fallback },
        };
        self.in_flight = false;
        self.handle = .{};
        self.request = null;
        return .{ .completed = completed };
    }

    fn worker(raw: u64) callconv(.c) i32 {
        const self: *Job = @ptrFromInt(raw);
        self.outcome = self.operation.execute(&self.audio);
        return 0;
    }
};
