//! The main entrypoint for the `ghostty` application. This also serves
//! as the process initialization code for the `libghostty` library.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const build_config = @import("build_config.zig");
const macos = @import("macos");
const cli = @import("cli.zig");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");

const App = @import("App.zig");
const Ghostty = @import("main_c.zig").Ghostty;
const global = @import("global.zig");

/// The return type for main() depends on the build artifact. The lib build
/// also calls "main" in order to run the CLI actions, but it calls it as
/// an API and not an entrypoint.
const MainReturn = switch (build_config.artifact) {
    .lib => noreturn,
    else => void,
};

pub fn main(minimal: std.process.Init.Minimal) !MainReturn {
    // We first start by initializing our global state. This will setup
    // process-level state we need to run the terminal. The reason we use
    // a global is because the C API needs to be able to access this state;
    // no other Zig code should EVER access the global state.
    global.init(.{ .main = minimal }) catch |err| {
        var buffer: [1024]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(
            std.Io.Threaded.global_single_threaded.io(),
            &buffer,
        );
        const stderr = &stderr_writer.interface;
        defer std.process.exit(1);
        const ErrSet = @TypeOf(err) || error{Unknown};
        switch (@as(ErrSet, @errorCast(err))) {
            error.MultipleActions => try stderr.print(
                "Error: multiple CLI actions specified. You must specify only one\n" ++
                    "action starting with the `+` character.\n",
                .{},
            ),

            error.InvalidAction => try stderr.print(
                "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                    "the '+' character.\n\n" ++
                    "All valid CLI actions can be listed with `ghostty +help`\n",
                .{},
            ),

            else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
        }
        try stderr.flush();
    };
    defer global.deinit();
    const alloc = global.alloc();

    if (comptime builtin.mode == .Debug) {
        std.log.warn("This is a debug build. Performance will be very poor.", .{});
        std.log.warn("You should only use a debug build for developing Ghostty.", .{});
        std.log.warn("Otherwise, please rebuild in a release mode.", .{});
    }

    // Execute our action if we have one
    if (global.action()) |action| {
        std.log.info("executing CLI action={}", .{action});
        std.process.exit(action.run(alloc) catch |err| err: {
            std.log.err("CLI action failed error={}", .{err});
            break :err 1;
        });
        return;
    }

    if (comptime build_config.app_runtime == .none) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: ghostty +<action> [flags]\n\n", .{});
        try stdout.print(
            \\This is the Ghostty helper CLI that accompanies the graphical Ghostty app.
            \\To launch the terminal directly, please launch the graphical app
            \\(i.e. Ghostty.app on macOS). This CLI can be used to perform various
            \\actions such as inspecting the version, listing fonts, etc.
            \\
            \\On macOS, the terminal can also be launched using `open -na Ghostty.app`,
            \\or `open -na Ghostty.app --args --foo=bar --baz=qux` to pass arguments.
            \\
            \\We don't have proper help output yet, sorry! Please refer to the
            \\source code or Discord community for help for now. We'll fix this in time.
            \\
        ,
            .{},
        );

        std.process.exit(0);
    }

    // Create our app state
    const app: *App = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    // Since - by definition - there are no surfaces when first started, the
    // quit timer may need to be started. The start timer will get cancelled if/
    // when the first surface is created.
    if (@hasDecl(apprt.App, "startQuitTimer")) app_runtime.startQuitTimer();

    // Run the GUI event loop
    try app_runtime.run();
}

// The function std.log will call.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // On Mac, we use unified logging. To view this:
    //
    //   sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
    //
    // macOS logging is thread safe so no need for locks/mutexes
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!global.logging().macos) break :macos;

        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

        // Convert our levels to Mac levels
        const mac_level: macos.os.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };

        macosLogger(scope).log(
            std.heap.c_allocator,
            mac_level,
            prefix ++ format,
            args,
        );
    }

    stderr: {
        // don't log debug messages to stderr unless we are a debug build
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;

        // skip if we are not logging to stderr
        if (!global.logging().stderr) break :stderr;

        // Lock so we are thread-safe
        var buf: [64]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();

        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        var time_buf: [16]u8 = undefined;
        const time_txt = localTimeOfDay(&time_buf);
        nosuspend stderr.file_writer.interface.print(
            "{s} " ++ level_txt ++ prefix ++ format ++ "\n",
            .{time_txt} ++ args,
        ) catch break :stderr;
        nosuspend stderr.file_writer.interface.flush() catch break :stderr;
    }
}

/// The wall-clock time of day, local, as `HH:MM:SS.mmm`.
///
/// Every line of the log carries one. Without it a log is only an ordering,
/// and the questions actually asked of it are about *when*: how long the gap
/// before the last line was, and whether a line lines up with a crash that
/// `coredumpctl` timestamps to the second.
///
/// Local rather than UTC because everything it gets compared against —
/// `coredumpctl`, `journalctl`, `ls -l` — is local. Milliseconds because the
/// gaps worth seeing are frame-sized.
fn localTimeOfDay(buf: []u8) []const u8 {
    const unknown = "--:--:--.---";

    // `localtime_r` is POSIX. Windows has `localtime_s` with a different
    // signature; not worth the trouble, so those builds simply have no
    // timestamp rather than a wrong one.
    if (comptime builtin.target.os.tag == .windows) return unknown;

    // The clock is read through libc rather than `std.Io.Timestamp`, which
    // wants an `Io` instance this function has no way to obtain: it runs on
    // any thread, and before and after the global state exists.
    var ts: Timespec = undefined;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return unknown;

    var tm: Tm = undefined;
    if (localtime_r(&ts.tv_sec, &tm) == null) return unknown;

    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        @as(u32, @intCast(tm.tm_hour)),
        @as(u32, @intCast(tm.tm_min)),
        @as(u32, @intCast(tm.tm_sec)),
        @as(u32, @intCast(@divTrunc(ts.tv_nsec, 1_000_000))),
    }) catch unknown;
}

/// `struct tm` as glibc lays it out. Only the fields up to `tm_isdst` are
/// standard; the two after it are the GNU extension, and are declared so that
/// the struct is the right size for `localtime_r` to fill in.
const Tm = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};

const Timespec = extern struct {
    tv_sec: c_long,
    tv_nsec: c_long,
};

const CLOCK_REALTIME: c_int = 0;

extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
extern "c" fn localtime_r(timep: *const c_long, result: *Tm) ?*Tm;

/// Returns the macOS unified logging logger for the given scope. The
/// logger is created once per scope and cached for the lifetime of the
/// process, because os_log object creation is slow (it shows up in
/// startup profiles when done per log call) and Apple's guidance is to
/// create loggers once and reuse them.
fn macosLogger(comptime scope: @TypeOf(.EnumLiteral)) *macos.os.Log {
    const S = struct {
        var cached: std.atomic.Value(?*macos.os.Log) = .init(null);
    };

    if (S.cached.load(.acquire)) |v| return v;

    // Create and attempt to store our logger. If we race with another
    // thread then we use theirs and release ours.
    const created = macos.os.Log.create(
        build_config.bundle_id,
        @tagName(scope),
    );
    if (S.cached.cmpxchgStrong(
        null,
        created,
        .acq_rel,
        .acquire,
    )) |existing| {
        created.release();
        return existing.?;
    }

    return created;
}

pub const std_options: std.Options = .{
    // Our log level is always at least info in every build mode.
    //
    // Note, we don't lower this to debug even with conditional logging
    // via GHOSTTY_LOG because our debug logs are very expensive to
    // calculate and we want to make sure they're optimized out in
    // builds.
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    },

    .logFn = logFn,

    // If are building for a non-MacOS Darwin target (e.g., iOS), we need to
    // disable stack tracing for the time being. This is due to the fact that
    // Zig switched to using _dyld_get_image_header_containing_address and some
    // other (deprecated) calls to speed up stack unwinding; these calls are
    // available on MacOS, but not on other platforms.
    //
    // A fix has already been submitted to exempt non-MacOS (but still Darwin)
    // targets, so this can likely be removed in Zig 0.17.0, or a 0.16.x patch
    // version if it releases beforehand.
    //
    // More details:
    //   https://codeberg.org/ziglang/zig/commit/89f86e46d278a35a613bbc662cdd3f65ffc76ed7
    //
    .allow_stack_tracing = if (builtin.target.os.tag.isDarwin() and builtin.target.os.tag != .macos)
        false
    else
        builtin.strip_debug_info,
};

test {
    _ = @import("pty.zig");
    _ = @import("Command.zig");
    _ = @import("font/main.zig");
    _ = @import("apprt.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("cli.zig");
    _ = @import("surface_mouse.zig");

    // Libraries
    _ = @import("tripwire.zig");
    _ = @import("benchmark/main.zig");
    _ = @import("crash/main.zig");
    _ = @import("datastruct/main.zig");
    _ = @import("inspector/main.zig");
    _ = @import("lib/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/main.zig");
    _ = @import("simd/main.zig");
    _ = @import("synthetic/main.zig");
    _ = @import("unicode/main.zig");
    _ = @import("unicode/props_uucode.zig");
    _ = @import("unicode/symbols_uucode.zig");

    // Extra
    _ = @import("extra/bash.zig");
    _ = @import("extra/fish.zig");
    _ = @import("extra/sublime.zig");
    _ = @import("extra/vim.zig");
    _ = @import("extra/zsh.zig");
}
