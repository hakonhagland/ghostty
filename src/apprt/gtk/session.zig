//! Saving and restoring the user-interface state of the GTK runtime.
//!
//! Ghostty can already do this on macOS, where AppKit's window restoration
//! does most of the work (`macos/Sources/Features/Terminal/TerminalRestorable.swift`).
//! There is no equivalent on Linux, so this module writes the same kind of
//! state — which windows were open, which tabs were in each of them, and
//! where each tab was — to a JSON file, and reads it back on the next launch.
//!
//! Deliberately out of scope for now: splits within a tab, and the scrollback
//! contents of each terminal. The schema is versioned and readers ignore
//! fields they do not recognize, so both can be added later without
//! invalidating files written by this version.
//!
//! Nothing here touches GTK. It is plain data plus file I/O so that it can be
//! unit tested; the code that walks the real widget tree lives in
//! `class/application.zig`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const global = @import("../../global.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.gtk_session);

/// Where the state file lives, relative to the XDG state directory
/// (`$XDG_STATE_HOME`, or `~/.local/state` when that is unset).
const subdir = "ghostty";
const filename = "ui-state.json";
const filename_tmp = "ui-state.json.tmp";

/// An upper bound on the size of a state file we are willing to read. Real
/// files are a few kilobytes; this only exists so that a corrupt or hostile
/// file cannot make us allocate without limit.
const max_read_size: std.Io.Limit = .limited(4 * 1024 * 1024);

/// The schema version written into every file.
///
/// Bump this only for a change that older readers would *misinterpret*.
/// Purely additive fields do not need a bump, because both the reader and the
/// writer ignore unknown fields.
pub const version: u32 = 1;

/// The whole saved state: an ordered list of windows.
pub const State = struct {
    version: u32 = version,
    windows: []const Window = &.{},

    /// One window, with its tabs in the order they appeared in the tab bar.
    pub const Window = struct {
        /// The window size in pixels, as GTK last reported it. Null means
        /// "we could not measure it", in which case the restored window is
        /// sized the way a brand new window would be.
        ///
        /// There is deliberately no position: on Wayland an application is
        /// not allowed to place its own windows, so a saved position could
        /// not be honored. See the `window-position-x` documentation in
        /// `src/config/Config.zig`.
        width: ?i32 = null,
        height: ?i32 = null,

        /// Index into `tabs` of the tab that was selected. Null, or out of
        /// range, means "select the first one".
        focused_tab: ?usize = null,

        tabs: []const Tab = &.{},
    };

    /// One tab. These are exactly the three things a user sets about a tab
    /// and would be annoyed to lose.
    pub const Tab = struct {
        /// The directory the terminal was in. Ghostty only knows this when
        /// shell integration is reporting it (OSC 7), so it can legitimately
        /// be null; such a tab is restored in the default directory.
        working_directory: ?[]const u8 = null,

        /// The title the user set on this tab by hand, if any. This is never
        /// the title the running program reported — that one belongs to the
        /// program, and restoring it would be a lie.
        title: ?[]const u8 = null,

        /// The project this tab belongs to, if the user assigned one. This
        /// field is specific to this fork; upstream Ghostty has no project
        /// concept.
        project: ?[]const u8 = null,
    };

    /// True when there is nothing worth writing. We never overwrite a good
    /// file with an empty one — see `saveUiState` in `class/application.zig`.
    pub fn isEmpty(self: State) bool {
        return self.windows.len == 0;
    }
};

/// The absolute path of the state file. Caller owns the returned memory.
pub fn path(alloc: Allocator) ![]u8 {
    var environ_map = try global.environMap();
    defer environ_map.deinit();

    const dir = try internal_os.xdg.state(
        global.io(),
        alloc,
        &environ_map,
        .{ .subdir = subdir },
    );
    defer alloc.free(dir);

    return try std.fs.path.join(alloc, &.{ dir, filename });
}

/// Turn a state into the bytes we would write. Caller owns the memory.
///
/// The output is indented rather than minified. The file is small, it is read
/// far less often than it is looked at by a confused human, and being able to
/// open it in an editor and see what Ghostty thought your session was is worth
/// more than the bytes.
pub fn serialize(alloc: Allocator, state: State) ![]u8 {
    var buffer: std.Io.Writer.Allocating = .init(alloc);
    errdefer buffer.deinit();
    try buffer.writer.print("{f}", .{std.json.fmt(
        state,
        .{ .whitespace = .indent_2 },
    )});
    return try buffer.toOwnedSlice();
}

/// Write a state to disk, replacing whatever was there.
///
/// The write goes to a temporary file which is then renamed over the real one.
/// Rename is atomic within a directory, so a crash — or a power cut — in the
/// middle of a write leaves either the old file or the new one, never a
/// half-written file that would fail to parse on the next launch.
pub fn save(alloc: Allocator, state: State) !void {
    const bytes = try serialize(alloc, state);
    defer alloc.free(bytes);

    const io = global.io();

    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const dir_path = try internal_os.xdg.state(
        io,
        alloc,
        &environ_map,
        .{ .subdir = subdir },
    );
    defer alloc.free(dir_path);

    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);

    // 0600: the working directories of every terminal you had open are not
    // something other users of the machine need to read.
    try dir.writeFile(io, .{
        .sub_path = filename_tmp,
        .data = bytes,
        .flags = switch (builtin.os.tag) {
            .windows => .{},
            else => .{ .permissions = .fromMode(0o600) },
        },
    });
    try dir.rename(filename_tmp, dir, filename, io);

    log.info("ui state written path={s}/{s} bytes={d}", .{
        dir_path,
        filename,
        bytes.len,
    });
}

/// Read the state file back.
///
/// Returns null — rather than an error — for every "there is simply nothing to
/// restore" case: no file, unreadable file, unparseable file, or a file
/// written by a schema version we do not understand. A bad state file must
/// never stop Ghostty from starting.
///
/// The result owns its strings and must be freed with `.deinit()`.
pub fn load(alloc: Allocator) ?std.json.Parsed(State) {
    const io = global.io();

    const file_path = path(alloc) catch |err| {
        log.warn("cannot determine ui state path err={}", .{err});
        return null;
    };
    defer alloc.free(file_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        file_path,
        alloc,
        max_read_size,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no ui state file at {s}", .{file_path});
            return null;
        },
        else => {
            log.warn("cannot read ui state path={s} err={}", .{ file_path, err });
            return null;
        },
    };
    defer alloc.free(bytes);

    return parse(alloc, bytes) catch |err| {
        log.warn("cannot parse ui state path={s} err={}", .{ file_path, err });
        return null;
    };
}

/// Parse state bytes. Split out from `load` so it can be tested without
/// touching the filesystem.
pub fn parse(alloc: Allocator, bytes: []const u8) !std.json.Parsed(State) {
    const parsed = try std.json.parseFromSlice(
        State,
        alloc,
        bytes,
        .{
            .ignore_unknown_fields = true,

            // `.alloc_always` is load-bearing, not a precaution. The default
            // for a slice input is `.alloc_if_needed`, which leaves any string
            // containing no escape sequences pointing *into* `bytes` rather
            // than copying it — and `bytes` is the file buffer, which the
            // caller frees as soon as parsing returns. Every working directory
            // we read would then be a dangling pointer, which is exactly the
            // shape of bug that survives a unit test (the buffer is still
            // there) and fails in the real program.
            .allocate = .alloc_always,
        },
    );
    errdefer parsed.deinit();

    if (parsed.value.version != version) {
        log.warn("ignoring ui state written by a different version: {d}", .{
            parsed.value.version,
        });
        return error.UnsupportedVersion;
    }

    return parsed;
}

test "serialize and parse a round trip" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const state: State = .{ .windows = &.{
        .{
            .width = 1200,
            .height = 800,
            .focused_tab = 1,
            .tabs = &.{
                .{
                    .working_directory = "/home/user/src",
                    .title = "build",
                    .project = "ghostty",
                },
                .{ .working_directory = "/tmp" },
            },
        },
    } };

    const bytes = try serialize(alloc, state);
    defer alloc.free(bytes);

    var parsed = try parse(alloc, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    const win = parsed.value.windows[0];
    try testing.expectEqual(@as(?i32, 1200), win.width);
    try testing.expectEqual(@as(?usize, 1), win.focused_tab);
    try testing.expectEqual(@as(usize, 2), win.tabs.len);
    try testing.expectEqualStrings("build", win.tabs[0].title.?);
    try testing.expectEqualStrings("ghostty", win.tabs[0].project.?);
    try testing.expectEqual(@as(?[]const u8, null), win.tabs[1].title);
}

test "parse tolerates fields it does not know" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A file written by a future version that also saves splits. We must read
    // what we understand and ignore the rest rather than refusing the file.
    const bytes =
        \\{
        \\  "version": 1,
        \\  "unknown_top_level": true,
        \\  "windows": [
        \\    {
        \\      "width": 640,
        \\      "splits": [{"ratio": 0.5}],
        \\      "tabs": [{"working_directory": "/tmp", "scrollback": "x.vt"}]
        \\    }
        \\  ]
        \\}
    ;

    var parsed = try parse(alloc, bytes);
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 1), parsed.value.windows.len);
    try testing.expectEqualStrings(
        "/tmp",
        parsed.value.windows[0].tabs[0].working_directory.?,
    );
}

test "parsed strings outlive the buffer they were parsed from" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // `load` reads the file into a buffer, parses it, and frees the buffer.
    // The parsed value must not point into that buffer. Parsing from a copy we
    // then free is what makes the difference visible: with the wrong parse
    // option this reads freed memory.
    const source =
        \\{"version":1,"windows":[{"tabs":[{"working_directory":"/home/user/src"}]}]}
    ;
    const bytes = try alloc.dupe(u8, source);

    var parsed = try parse(alloc, bytes);
    defer parsed.deinit();

    alloc.free(bytes);

    try testing.expectEqualStrings(
        "/home/user/src",
        parsed.value.windows[0].tabs[0].working_directory.?,
    );
}

test "parse rejects a different schema version" {
    const testing = std.testing;
    const alloc = testing.allocator;

    try testing.expectError(
        error.UnsupportedVersion,
        parse(alloc, "{\"version\": 999, \"windows\": []}"),
    );
}

test "an empty state is empty" {
    const testing = std.testing;
    const state: State = .{};
    try testing.expect(state.isEmpty());
}
