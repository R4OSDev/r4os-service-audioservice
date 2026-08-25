const std = @import("std");

pub fn matches(stored_client_id: u32, stored_stream_id: u32, client_id: u32, stream_id: u32) bool {
    return client_id != 0 and stored_client_id == client_id and stored_stream_id == stream_id;
}

pub fn clientIsRunning(client_id: u32, running_client_ids: []const u32) bool {
    if (client_id == 0) return false;
    for (running_client_ids) |running_id| {
        if (running_id == client_id) return true;
    }
    return false;
}

pub fn runningRecordMatches(client_id: u32, record_client_id: u32, record_state: u8, running_state: u8) bool {
    return client_id != 0 and client_id == record_client_id and record_state == running_state;
}

pub fn isSilence(data: []const u8) bool {
    for (data) |sample_byte| {
        if (sample_byte != 0) return false;
    }
    return true;
}

test "stream access requires both client and stream identity" {
    try std.testing.expect(matches(17, 42, 17, 42));
    try std.testing.expect(!matches(17, 42, 18, 42));
    try std.testing.expect(!matches(17, 42, 17, 43));
    try std.testing.expect(!matches(0, 42, 0, 42));
}

test "dead clients are distinguishable from running clients" {
    const running = [_]u32{ 3, 8, 13 };
    try std.testing.expect(clientIsRunning(8, running[0..]));
    try std.testing.expect(!clientIsRunning(9, running[0..]));
    try std.testing.expect(!clientIsRunning(0, running[0..]));
    try std.testing.expect(runningRecordMatches(8, 8, 0, 0));
    try std.testing.expect(!runningRecordMatches(8, 8, 1, 0));
}

test "s16le silence is detected without manufacturing payload" {
    const silence = [_]u8{0} ** 16;
    var signal = silence;
    signal[9] = 1;
    try std.testing.expect(isSilence(silence[0..]));
    try std.testing.expect(!isSilence(signal[0..]));
}
