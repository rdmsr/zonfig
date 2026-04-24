const std = @import("std");
const posix = std.posix;

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    backspace,
    esc,
};

pub const RawMode = struct {
    fd: posix.fd_t,
    old: posix.termios,

    pub fn enable(fd: posix.fd_t) !RawMode {
        const old = try posix.tcgetattr(fd);
        var raw = old;

        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;

        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;

        try posix.tcsetattr(fd, .FLUSH, raw);
        return .{ .fd = fd, .old = old };
    }

    pub fn disable(self: RawMode) void {
        posix.tcsetattr(self.fd, .FLUSH, self.old) catch {};
    }
};

pub fn readKey(r: anytype) !?Key {
    const c = r.takeByte() catch |err| switch (err) {
        error.EndOfStream => return null,
        else => return err,
    };

    if (c == '\r' or c == '\n') return .enter;
    if (c == 127) return .backspace;

    if (c == 0x1b) {
        const b1 = r.takeByte() catch return .esc;
        if (b1 != '[') return .esc;

        const b2 = r.takeByte() catch return .esc;
        return switch (b2) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            else => .esc,
        };
    }

    return .{ .char = c };
}
