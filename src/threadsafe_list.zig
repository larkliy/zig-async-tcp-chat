const std = @import("std");
const Io = std.Io;

pub fn ConcurrentList(comptime T: type) type {
    return struct {
        list: std.ArrayList(T),
        gpa: std.mem.Allocator,
        mutex: Io.Mutex,

        const Self = @This();

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ 
                .gpa = gpa,
                .list = .empty,
                .mutex = .init
            };
        }

        pub fn append(self: *Self, io: Io, value: T) !void {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            try self.list.append(self.gpa, value);
        }

        pub fn orderedRemove(self: *Self, io: Io, i: usize) !T {
            try self.mutex.lock(io);
            defer self.mutex.unlock(io);

            return self.list.orderedRemove(i);
        }
    };
}
