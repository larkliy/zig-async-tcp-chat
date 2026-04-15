const std = @import("std");
const User = @import("user.zig").User;

const Io = std.Io;
const net = Io.net;

pub const ClientContext = struct { 
    user: *User, 
    reader: *net.Stream.Reader, 
    writer: *net.Stream.Writer, 
    stream: net.Stream,

    pub fn send(self: *ClientContext, data: []const u8) !void {
        try self.writer.interface.writeAll(data);
        try self.writer.interface.flush();
    }

    pub fn readln(self: *ClientContext) !?[]const u8 {
        self.reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };

        const line = try self.reader.interface.takeDelimiter('\n');
        if (line == null) return null;

        return std.mem.trim(u8, line.?, "\r\n");
    }

    pub fn print(self: *ClientContext, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.interface.print(fmt, args);
        try self.writer.interface.flush();
    }
};
