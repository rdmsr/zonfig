# zonfig

A kconfig-like configuration system for Zig projects, using ZON as the schema and config format.

![Demo](assets/demo.gif)

## Overview

`zonfig` provides a TUI for editing build configuration based on `ncurses` and generates a Zig module your code can import directly.
Configuration is defined in a ZON schema file, and the current values are stored in a separate ZON config file.

### Features
- Multiple config formats: ZON and JSON are both supported.
- Support for boolean expressions in `depends_on` to control entry visibility.
- Compile-time, type-safe access to config values in your code.


## Schema

Define your configuration in a schema file:

```zig
.{
    .title = "My Project Configuration",
    .entries = .{
        .{
            .kind = .bool,
            .key = "enable_logging",
            .label = "Enable logging",
            .default = .{ .bool = false },
        },
        .{
            .kind = .choice,
            .key = "build_mode",
            .label = "Build mode",
            .default = .{ .choice = "Debug" },
            .options = .{
                .{ .value = "Debug" },
                .{ .value = "ReleaseSafe" },
                .{ .value = "ReleaseFast" },
                .{ .value = "ReleaseSmall" },
            },
        },
    },
}
```

Entries support the following kinds: `bool`, `int`, `string`, `choice`, and `menu` for grouping. The `depends_on` field accepts boolean expressions:

```zig
.depends_on = .{ .key = "some_bool" }
.depends_on = .{ .key_eq = .{.key = "some_choice", .value = "some_option"} }
.depends_on = .{ .not = .{ .key = "some_bool" } }
.depends_on = .{ .all = .{ .{ .key = "A" }, .{ .key = "B" } } }
.depends_on = .{ .any = .{ .{ .key = "A" }, .{ .not = .{ .key = "B" } } } }
```

## Installation

Add zonfig to your `build.zig.zon`:

```zig
.dependencies = .{
    .zonfig = .{
        .url = "...",
        .hash = "...",
    },
},
```

## Usage
In your `build.zig`:

```zig
const zonfig = @import("zonfig");

pub fn build(b: *std.Build) void {
    const zonfig_dep = b.dependency("zonfig", .{ .target = target });

    // Add `zig build config` step to launch the TUI editor.
    // You should check for the presence of the config file (.config.zon) and error if not present.
    zonfig.addConfigStep(b, zonfig_dep, "config.zon", ".config.zon");

    // Create a module your code can import.
    const config_mod = zonfig.createConfigModule(b, zonfig_dep, "config.zon", ".config.zon");
    exe.root_module.addImport("config", config_mod);
}
```

Run the TUI to edit your configuration:

```sh
zig build config
```

Then import the generated module in your code:

```zig
const config = @import("config");

pub fn main() void {
    if (config.enable_logging) {
        // ...
    }
}
```

The config file should be committed to version control. It is only regenerated when you run `zig build config`.

An example is provided in the `example/` directory.
