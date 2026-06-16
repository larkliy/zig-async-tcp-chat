const Self = @This();

const std = @import("std");
const User = @import("user.zig").User;

const Io = std.Io;
const net = Io.net;

user: User,
reader: net.Stream.Reader,
writer: net.Stream.Writer,
stream: net.Stream,
last_activity: std.atomic.Value(i64),
allocator: std.mem.Allocator,
kicked: std.atomic.Value(bool),

pub fn init(self: *Self, io: Io, allocator: std.mem.Allocator, stream: net.Stream) !void {
    const reader_buf = try allocator.alloc(u8, 1024);
    const writer_buf = try allocator.alloc(u8, 1024);

    errdefer {
        allocator.free(reader_buf);
        allocator.free(writer_buf);
    }

    self.allocator = allocator;
    self.stream = stream;
    self.reader = stream.reader(io, reader_buf);
    self.writer = stream.writer(io, writer_buf);
    self.user = .{ .allocator = allocator, .is_authorized = false, .name = null };
    self.last_activity = .init(Io.Timestamp.now(io, .awake).toMilliseconds());
    self.kicked = .init(false);
}

pub fn isMe(self: *Self, other: *Self) bool {
    return self.stream.socket.handle == other.stream.socket.handle;
}

pub fn send(self: *Self, data: []const u8) !void {
    try self.writer.interface.writeAll(data);
    try self.writer.interface.flush();
}

pub fn readln(self: *Self) !?[]const u8 {
    const line = try self.reader.interface.takeDelimiter('\n');
    if (line == null) return null;

    return std.mem.trim(u8, line.?, "\r\n");
}

pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
    try self.writer.interface.print(fmt, args);
    try self.writer.interface.flush();
}

pub fn update_activity(self: *Self, io: Io) void {
    self.last_activity.store(Io.Timestamp.now(io, .awake).toMilliseconds(), .monotonic);
}

pub fn deinit(self: *Self, io: Io) void {
    self.user.deinit();

    self.allocator.free(self.reader.interface.buffer);
    self.allocator.free(self.writer.interface.buffer);

    self.stream.shutdown(io, .both) catch return;
    self.stream.close(io);
}
