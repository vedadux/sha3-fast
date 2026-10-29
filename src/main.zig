const std = @import("std");
const Io = std.Io;
const sha3_fast = @import("sha3_fast");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const n = sha3_fast.native_parallelism;
    var msgs: [n][32]u8 = undefined;
    var msg_ptrs: [n]*const [32]u8 = undefined;
    for (&msgs, &msg_ptrs, 0..) |*m, *p, k| {
        @memset(m, @truncate(k));
        p.* = m;
    }

    const rate = sha3_fast.Shake256(n).block_bytes;
    var out: [n][rate]u8 = undefined;
    var out_ptrs: [n]*[rate]u8 = undefined;
    for (&out_ptrs, &out) |*p, *o| p.* = o;

    var sponge = sha3_fast.Shake256(n).init(32, msg_ptrs);
    sponge.squeezeBlocks(1, out_ptrs);

    try stdout.print("sha3_fast (native_parallelism = {d})\n", .{n});
    for (out, 0..) |digest, k| {
        try stdout.print("lane {d} SHAKE256[0..32]: {x}\n", .{ k, digest[0..32] });
    }
    try stdout.flush();
}

test "root module exports match std Shake256" {
    const n = sha3_fast.native_parallelism;
    var msgs: [n][32]u8 = undefined;
    var msg_ptrs: [n]*const [32]u8 = undefined;
    for (&msgs, &msg_ptrs, 0..) |*m, *p, k| {
        @memset(m, @truncate(k));
        p.* = m;
    }

    const rate = sha3_fast.Shake256(n).block_bytes;
    var out: [n][rate]u8 = undefined;
    var out_ptrs: [n]*[rate]u8 = undefined;
    for (&out_ptrs, &out) |*p, *o| p.* = o;

    var sponge = sha3_fast.Shake256(n).init(32, msg_ptrs);
    sponge.squeezeBlocks(1, out_ptrs);

    for (msgs, out) |m, o| {
        var expected: [rate]u8 = undefined;
        std.crypto.hash.sha3.Shake256.hash(&m, &expected, .{});
        try std.testing.expectEqualSlices(u8, &expected, &o);
    }
}

