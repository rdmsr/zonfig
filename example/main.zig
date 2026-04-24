const std = @import("std");
const config = @import("config");

pub fn main() void {
    std.debug.print("My favorite fruit is {s}\n", .{@tagName(config.fruit)});
}
