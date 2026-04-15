const std = @import("std");
const Io = std.Io;
const net = Io.net;


pub const Helper = struct {
    pub fn send(io: Io, stream: net.Stream, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &buf);

        try writer.interface.print(fmt, args);
        try writer.interface.flush();
    }
};
