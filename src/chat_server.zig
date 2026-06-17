const Self = @This();

const std = @import("std");

const Io = std.Io;
const net = Io.net;

const ClientContext = @import("client_context.zig");
const Helpers = @import("server_helpers.zig");
const ConcurrentList = @import("concurrent_list.zig").ConcurrentList;
const User = @import("user.zig").User;

const Literals = @import("literals.zig");
const SystemLiterals = Literals.SystemLiterals;
const UserLiterals = Literals.UserLiterals;

io: Io,
gpa: std.mem.Allocator,
server: net.Server,
client_group: Io.Group,
clients: ConcurrentList(*ClientContext),

pub fn init(io: Io, gpa: std.mem.Allocator) Self {
    return .{ 
        .io = io, 
        .gpa = gpa, 
        .server = undefined, 
        .client_group = .init, 
        .clients = .init(gpa) 
    };
}

pub fn run(self: *Self, address: []const u8, port: u16) !void {
    const ip_address = try net.IpAddress.parse(address, port);

    self.server = try ip_address.listen(self.io, .{});

    std.log.info("Chat server running on {s}:{d}", .{ address, port });

    try self.client_group.concurrent(self.io, watchdogTask, .{self});

    while (true) {
        const stream = self.server.accept(self.io) catch |err| {
            if (err == error.Canceled) {
                std.log.info("Accept canceled, shutting down loop...", .{});
                break;
            }

            std.log.err("Accept error: {s}", .{@errorName(err)});
            continue;
        };

        try self.client_group.concurrent(self.io, handleClient, .{ self, stream });
    }

    self.server.deinit(self.io);
}

fn handleClient(self: *Self, stream: net.Stream) Io.Cancelable!void {
    const io = self.io;

    const client_ctx = self.gpa.create(ClientContext) catch {
        std.log.err("Out of memory while creating ClientContext object.", .{});
        return;
    };

    client_ctx.init(io, self.gpa, stream) catch |err| {
        std.log.err("An error ocurred while ClientContext init: {}", .{err});
        return;
    };

    self.clients.append(self.io, client_ctx) catch {
        std.log.err("Out of memory while creating client append object.", .{});
        return;
    };

    var buf: [512]u8 = undefined;
    const ip_fmt = std.fmt.bufPrint(&buf, "{f}", .{stream.socket.address}) catch return;

    defer {
        std.log.info("Closing connection from {s}", .{ip_fmt});

        client_ctx.deinit(io);
        self.clients.removeByValue(self.io, client_ctx) catch {};

        self.gpa.destroy(client_ctx);
    }

    std.log.info("Client connected from {s}", .{ip_fmt});

    while (true) {
        if (client_ctx.kicked.load(.acquire)) return;

        if (!client_ctx.user.is_authorized) {
            self.handle_auth(client_ctx) catch |err| {
                std.log.err("Connection dropped/timed out for {s}. Error: {}", .{ ip_fmt, err });
                return;
            };

            continue;
        }

        self.handle_commands(client_ctx) catch |err| switch (err) {
            error.UserExit => {
                std.log.info("User {s} disconnected", .{client_ctx.user.name.?});
                self.sendToOthers(client_ctx, UserLiterals.Disconnected) catch return;
            },
            else => {
                std.log.err("Connection dropped/timed out for {s}. Error: {}", .{ ip_fmt, err });
                return;
            },
        };
    }
}

fn handle_auth(self: *Self, ctx: *ClientContext) !void {
    try ctx.send(SystemLiterals.Welcome);

    const name = ctx.readln() catch |err| {
        if (err == error.StreamTooLong) {
            try ctx.send(SystemLiterals.MessageTooLong);
            return;
        }
        return err;
    };

    if (name == null) return;
    
    const clients_snapshot = try self.clients.getSnapshot(self.io);
    defer self.gpa.free(clients_snapshot);

    for (clients_snapshot) |client| {
        if (client.user.name) |other_name| {
            if (std.mem.eql(u8, other_name, name.?)) {
                try ctx.send(SystemLiterals.NameAlreadyUsed);
                return;
            }
        }
    }

    try ctx.user.setName(name.?);

    std.log.info("User {s} authenticated", .{name.?});

    try self.sendToOthers(ctx, UserLiterals.Joined);

    try ctx.send(SystemLiterals.Help);
}

fn handle_commands(self: *Self, ctx: *ClientContext) !void {
    const command = ctx.readln() catch |err| {
        if (err == error.StreamTooLong) {
            try ctx.send(SystemLiterals.MessageTooLong);
            return;
        }
        return err;
    };

    if (command == null) return;

    if (std.mem.startsWith(u8, command.?, "/exit")) {
        std.log.info("User {s} requested exit", .{ctx.user.name.?});
        return error.UserExit;
    } else if (std.mem.eql(u8, command.?, "/list")) {
        try self.sendInfoAboutOthers(ctx);
    } else if (std.mem.eql(u8, command.?, "/help")) {
        try ctx.send(SystemLiterals.Help);
    } else if (std.mem.startsWith(u8, command.?, "/msg")) {
        try self.sendPrivateMessage(command.?, ctx);
    } else {
        try self.sendToOthers(ctx, command.?);
    }

    ctx.update_activity(self.io);
}

fn sendPrivateMessage(self: *Self, command: []const u8, ctx: *ClientContext) !void {
    var username_opt: ?[]const u8 = null;
    var message_opt: ?[]const u8 = null;

    var iter = std.mem.tokenizeScalar(u8, command, ' ');
    _ = iter.next(); // command itself: /msg 
    username_opt = iter.next();
    message_opt = iter.rest();

    if (username_opt == null or message_opt == null) {
        try ctx.send(SystemLiterals.UsernameOrMessageNull);
        return;
    }

    const clients_snapshot = try self.clients.getSnapshot(self.io);
    defer self.gpa.free(clients_snapshot);

    for (clients_snapshot) |client| {
        if (client.user.name) |name| {
            if (std.mem.eql(u8, username_opt.?, name)) {
                try Helpers.print(self.io, client.stream, "[PM] {s}: {s}\n", .{ ctx.user.name.?, message_opt.? });
                break;
            }
        }
    }

    try ctx.send(SystemLiterals.MessageSent);
}

fn sendInfoAboutOthers(self: *Self, ctx: *ClientContext) !void {
    const clients_snapshot = try self.clients.getSnapshot(self.io);
    defer self.gpa.free(clients_snapshot);

    const client_count = clients_snapshot.len;

    try ctx.print(SystemLiterals.UsersOnline, .{client_count});

    var should_cut_info = false;

    if (client_count > 10)
        should_cut_info = true;

    for (clients_snapshot) |other_ctx| {
        if (ctx.stream.socket.handle == other_ctx.stream.socket.handle) {
            try ctx.print(" - You\n", .{});
            continue;
        }

        if (other_ctx.user.name) |name| {
            try ctx.print(" - {s}\n", .{name});
        }

        if (should_cut_info) {
            try ctx.print("   ...\n", .{});
            break;
        }
    }
}

fn sendToOthers(self: *Self, ctx: *ClientContext, message: []const u8) !void {
    const io = self.io;
    const gpa = self.gpa;

    const clients_snapshot = try self.clients.getSnapshot(io);
    defer gpa.free(clients_snapshot);

    for (clients_snapshot) |other_ctx| {
        if (ctx.isMe(other_ctx)) continue;
        if (!other_ctx.user.is_authorized) continue;

        try Helpers.print(io, other_ctx.stream, "\n[MESSAGE] {s}: {s}\n", .{ ctx.user.name.?, message });
    }
}

fn watchdogTask(self: *Self) void {
    const timeout_ms: i64 = 60 * std.time.ms_per_s;

    while (true) {
        self.io.sleep(.fromSeconds(60), .awake) catch return;

        const now = Io.Timestamp.now(self.io, .awake).toMilliseconds();

        const clients_snapshot = self.clients.getSnapshot(self.io) catch continue;
        defer self.gpa.free(clients_snapshot);

        for (clients_snapshot) |ctx| {
            const last = ctx.last_activity.load(.monotonic);

            if (now - last > timeout_ms) {
                std.log.info("Kicking user due to inactivity", .{});

                Helpers.print(self.io, ctx.stream, "[KICK] {s}", .{SystemLiterals.KickedByInactivity}) catch {};

                ctx.kicked.store(true, .release);
                ctx.stream.close(self.io);
            }
        }
    }
}

pub fn deinit(self: *Self) void {
    self.client_group.cancel(self.io);
    self.client_group.await(self.io) catch {};

    const clients_snapshot = self.clients.getSnapshot(self.io) catch |err| {
        std.log.err("Failed to get clients snapshot during deinit: {s}", .{@errorName(err)});
        return;
    };

    for (clients_snapshot) |ctx| {
        ctx.stream.close(self.io);
    }

    self.clients.deinit(self.io) catch {};

    std.log.info("Server resources cleared.", .{});
}
