const std = @import("std");

pub const User = struct {
    name: ?[]u8 = null,
    is_authorized: bool = false,
    allocator: std.mem.Allocator,

    pub fn setName(self: *User, name: []const u8) !void {
        if (self.name == null)
            self.name = try self.allocator.dupe(u8, name);

        //if a name is written, then this (in theory XD) should mean that the user is authorized...
        self.is_authorized = true;
    }

    pub fn deinit(self: *User) void {
        if (self.name) |name| 
            self.allocator.free(name);
    }
};
