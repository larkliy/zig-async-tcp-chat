const std = @import("std");
const Io = std.Io; // Или как вы импортируете ваш Io

pub const Logger = struct {
    const Self = @This();

    io: Io,
    writer: *Io.Writer,
    should_console_print: bool = true,

    pub fn init(io: Io, writer: *Io.Writer, should_console_print: bool) Logger {
        return Logger{
            .io = io,
            .writer = writer,
            .should_console_print = should_console_print,
        };
    }

    fn writePrefix(self: *Self, comptime level:[]const u8) !void {
        const time = Io.Clock.real.now(self.io);
        
        const seconds_i64 = time.toSeconds();
        const secs = @as(u64, @intCast(seconds_i64));

        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = secs };
        const epoch_day = epoch_seconds.getEpochDay();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_seconds = epoch_seconds.getDaySeconds();

        try self.writer.print("[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}] [{s}] ", .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            level,
        });
    }

    pub fn log_info(self: *Self, comptime fmt:[]const u8, args: anytype) !void {
        const prev_protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(prev_protection);

        if (self.should_console_print) {
            std.log.info(fmt, args);
        }

        try self.writePrefix("INFO");
        try self.writer.print(fmt ++ "\n", args);
        try self.writer.flush(); 
    }

    pub fn log_error(self: *Self, comptime fmt:[]const u8, args: anytype) !void {
        const prev_protection = self.io.swapCancelProtection(.blocked);
        defer _ = self.io.swapCancelProtection(prev_protection);
        
        if (self.should_console_print) {
            std.log.err(fmt, args);
        }

        try self.writePrefix("ERROR");
        try self.writer.print(fmt ++ "\n", args);
        
        try self.writer.flush();
    }
};