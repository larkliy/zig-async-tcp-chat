const std = @import("std");
const ChatServer = @import("server.zig").ChatServer;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const port = 8080;

    var server = ChatServer.init(io, gpa, true);
    defer server.deinit();

    try server.run("0.0.0.0", port);
}