const std = @import("std");
const User = @import("user.zig").User;
const ClientContext = @import("client_context.zig").ClientContext;
const Helper = @import("herlpers.zig").Helper;
const Logger = @import("logger.zig").Logger;

const Io = std.Io;
const net = Io.net;
const ConcurrentList = @import("concurrent_list.zig").ConcurrentList;


pub const ChatServer = struct {
    const Self = @This();

    io: Io,
    gpa: std.mem.Allocator,
    server: net.Server,
    client_group: Io.Group,
    streams: ConcurrentList(net.Stream),
    users: ConcurrentList(User),
    logger: Logger,

    pub fn init(io: Io, gpa: std.mem.Allocator, logger: Logger) ChatServer {
        return ChatServer{
            .io = io,
            .gpa = gpa,
            .server = undefined,
            .client_group = .init,
            .streams = .init(gpa),
            .users = .init(gpa),
            .logger = logger
        };
    }

    pub fn run(self: *Self, address: []const u8, port: u16) !void {
        const ip_address = try net.IpAddress.parse(address, port);

        self.server = try ip_address.listen(self.io, .{});

        try self.logger.log_info("Chat server running on {s}:{d}", .{address, port});
        
        while (true) {
            const stream = self.server.accept(self.io) catch |err| {

                if (err == error.Canceled) {
                    try self.logger.log_info("Accept canceled, shutting down loop...", .{});
                    break; 
                }

                try self.logger.log_error("Accept error: {s}", .{@errorName(err)});
                continue;
            };

            self.streams.append(self.io, stream) catch |err| {
                try self.logger.log_error("Stream append error: {s}", .{@errorName(err)});
                continue;
            };

            self.client_group.async(self.io, handle_client, .{self, stream});
        }
        
        self.server.deinit(self.io);
    }

    fn handle_client(self: *Self, stream: net.Stream) void {
        handleClientInternal(self, stream) catch |err| {
            self.logger.log_error("Client handling error: {s}", .{@errorName(err)}) catch unreachable;
        };
    }

    fn handleClientInternal(self: *Self, stream: net.Stream) !void {
        const io = self.io;

        var buf: [100]u8 = undefined;
        const ip_fmt = try std.fmt.bufPrint(&buf, "{f}", .{stream.socket.address}); 

        defer {
            self.logger.log_info("Closing connection from {s}", .{ip_fmt}) catch unreachable;
            stream.close(self.io);
        }

        var writer_buf: [4096]u8 = undefined;
        var reader_buf: [4096]u8 = undefined;

        var user = User{
            .is_authorized = false,
            .name = null
        };

        var reader = stream.reader(io, &reader_buf);
        var writer = stream.writer(io, &writer_buf);

        var client_ctx = ClientContext{
            .user = &user,
            .reader = &reader,
            .writer = &writer,
            .stream = stream
        };

        try self.logger.log_info("Client connected from {s}", .{ip_fmt});

        while (true) {
            if (!client_ctx.user.is_authorized) {
                try self.handle_auth(&client_ctx);
                continue;
            } else {
                self.handle_commands(&client_ctx) catch |err| switch (err) {
                    error.UserExit => {
                        try self.logger.log_info("User {s} disconnected", .{client_ctx.user.name.?});
                        return;
                    },
                    else => return err,
                };
            }
        }
    }

    fn handle_auth(self: *Self, ctx: *ClientContext) !void {
        try ctx.send("Enter your name: ");

        const name = try ctx.readln();

        if (name == null) return;

        ctx.user.name = try self.gpa.dupe(u8, name.?);
        ctx.user.is_authorized = true;
        
        try self.logger.log_info("User {s} authenticated", .{name.?});
    }

    fn handle_commands(self: *Self, ctx: *ClientContext) !void {
        try ctx.send("Enter commands (type /exit to disconnect): ");

        const command = try ctx.readln();
        if (command == null) return;

        if (std.mem.startsWith(u8, command.?, "/exit")) {
            try self.logger.log_info("User {s} requested exit", .{ctx.user.name.?});
            return error.UserExit;
        } else {
            try self.sendToOthers(ctx, command.?);
        }
    }

    fn sendToOthers(self: *Self, ctx: *ClientContext, message: []const u8) !void {
        const io = self.io;
        const gpa = self.gpa;

        const streams_snapshot = try self.streams.getSnapshot(io);
        defer gpa.free(streams_snapshot);

        for (streams_snapshot) |stream| {
            if (ctx.stream.socket.handle == stream.socket.handle) continue;

            try Helper.send(
                io, stream, 
                "[MESSAGE] {s}: {s}\n", 
                .{ ctx.user.name.?, message }
            );
        }
    }

    pub fn deinit(self: *Self) void {
        self.client_group.cancel(self.io);
        self.client_group.await(self.io) catch {};

        self.streams.deinit(self.io) catch {};

        const snapshot = self.users.getSnapshot(self.io) catch |err| {
            self.logger.log_error("Failed to get users snapshot during deinit: {s}", .{@errorName(err)}) catch {};
            return;
        };

        defer self.gpa.free(snapshot);

        for (snapshot) |user| {
            if (user.name) |name| self.gpa.free(name);
        }

        self.users.deinit(self.io) catch {};

        self.logger.log_info("Server resources cleared.", .{}) catch {};
    }
};