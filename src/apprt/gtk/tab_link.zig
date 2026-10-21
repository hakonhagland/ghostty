//! `gho:` links: a markdown link that names one tab, so that another program
//! (a note app, say) can bring that tab to the front later.
//!
//!     [gho:build](gho:ghostty?id=261021042815-k7qp&title=build&dir=%2Fsrc&window=work)
//!
//! The path part is the tab's project. `id` finds the tab while it is open;
//! the other fields are what is needed to open it again once it is gone. The
//! link text after `gho:` is for reading only and is never parsed back.
//!
//! Every value is percent-encoded, `/` included, so that the target contains
//! no spaces, parentheses, `?`, `&` or `#` of its own. Specific to this fork.
//!
//! Nothing here touches GTK, so it can be tested on its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const scheme = "gho";

/// The fields of one link. Empty strings are treated like null when writing.
pub const Fields = struct {
    id: ?[]const u8 = null,
    project: ?[]const u8 = null,
    title: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    window: ?[]const u8 = null,
};

/// The query parameters, in the order they are written.
const params = .{ "id", "title", "dir", "window" };

/// Write the whole markdown link: `[gho:<label>](<target>)`.
///
/// `label` is escaped the way markdown expects inside `[...]`, and a line
/// break in it becomes a space, so the link always stays on one line.
pub fn writeLink(w: *std.Io.Writer, label: []const u8, fields: Fields) !void {
    try w.writeAll("[" ++ scheme ++ ":");
    for (label) |c| switch (c) {
        '[', ']', '\\' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        '\n', '\r', '\t' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
    try w.writeAll("](");
    try writeTarget(w, fields);
    try w.writeByte(')');
}

/// Write only the target: `gho:<project>?id=…&title=…&dir=…&window=…`.
pub fn writeTarget(w: *std.Io.Writer, fields: Fields) !void {
    try w.writeAll(scheme ++ ":");
    if (fields.project) |p| try writeEscaped(w, p);

    var sep: u8 = '?';
    inline for (params) |name| {
        if (@field(fields, name)) |v| if (v.len > 0) {
            try w.writeByte(sep);
            sep = '&';
            try w.writeAll(name ++ "=");
            try writeEscaped(w, v);
        };
    }
}

/// Percent-encode everything except the unreserved characters of RFC 3986.
fn writeEscaped(w: *std.Io.Writer, value: []const u8) !void {
    for (value) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

pub const ParseError = error{
    /// The target does not start with `gho:`.
    NotATabLink,
    /// A `%` not followed by two hex digits, or a value containing NUL.
    InvalidEncoding,
} || Allocator.Error;

/// Parse a link target, as the note app passes it. Unknown parameters are
/// ignored, and a `#fragment` is dropped. Every returned string is allocated
/// with `alloc`, NUL-terminated; pass an arena and free it as a whole.
pub fn parse(alloc: Allocator, target: []const u8) ParseError!Fields {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    const prefix = scheme ++ ":";
    if (trimmed.len < prefix.len or
        !std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix))
        return error.NotATabLink;

    var rest = trimmed[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '#')) |i| rest = rest[0..i];

    const q = std.mem.indexOfScalar(u8, rest, '?');
    const path = if (q) |i| rest[0..i] else rest;
    const query = if (q) |i| rest[i + 1 ..] else "";

    var fields: Fields = .{};
    if (path.len > 0) fields.project = try decode(alloc, path);

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const value = try decode(alloc, pair[eq + 1 ..]);
        inline for (params) |name| {
            if (std.mem.eql(u8, key, name)) @field(fields, name) = value;
        }
    }

    // An empty value means "not given", the same as a missing parameter.
    inline for (.{ "project", "id", "title", "dir", "window" }) |name| {
        if (@field(fields, name)) |v| if (v.len == 0) {
            @field(fields, name) = null;
        };
    }

    return fields;
}

fn decode(alloc: Allocator, value: []const u8) ParseError![:0]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(alloc, value.len + 1);
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c != '%') {
            out.appendAssumeCapacity(c);
            continue;
        }
        if (i + 2 >= value.len) return error.InvalidEncoding;
        const byte = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch
            return error.InvalidEncoding;
        if (byte == 0) return error.InvalidEncoding;
        out.appendAssumeCapacity(byte);
        i += 2;
    }
    return try out.toOwnedSliceSentinel(alloc, 0);
}

/// The length of an id from `writeId`.
pub const id_len = 12 + 1 + 4;

/// Write a new tab id: `stamp` (the local time as `yymmddHHMMSS`), a dash, and
/// four random characters, as in `261021042815-k7qp`. The time keeps ids
/// readable; the random part keeps apart the many tabs that get an id in the
/// same second when an older state file is first restored. The alphabet
/// leaves out characters that are easy to misread (`0 o 1 l`).
pub fn writeId(w: *std.Io.Writer, stamp: []const u8, random: std.Random) !void {
    const alphabet = "abcdefghijkmnpqrstuvwxyz23456789";
    try w.writeAll(stamp);
    try w.writeByte('-');
    for (0..4) |_| try w.writeByte(alphabet[random.uintLessThan(usize, alphabet.len)]);
}

fn testTarget(fields: Fields) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer buf.deinit();
    try writeTarget(&buf.writer, fields);
    return try buf.toOwnedSlice();
}

test "write a target with every field" {
    const target = try testTarget(.{
        .id = "261021042815-k7qp",
        .project = "opm",
        .title = "rescoup build",
        .dir = "/home/u/git",
        .window = "work",
    });
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings(
        "gho:opm?id=261021042815-k7qp&title=rescoup%20build&dir=%2Fhome%2Fu%2Fgit&window=work",
        target,
    );
}

test "write a target with no project and missing fields" {
    const target = try testTarget(.{ .id = "x", .title = "", .window = null });
    defer std.testing.allocator.free(target);
    try std.testing.expectEqualStrings("gho:?id=x", target);
}

test "the target never contains characters the note app stops at" {
    const target = try testTarget(.{
        .project = "a b(c)?d&e#f%g",
        .id = "i",
        .title = "t [x] (y)",
        .dir = "/p q/ø",
    });
    defer std.testing.allocator.free(target);
    for (target) |c| {
        try std.testing.expect(c != ' ' and c != '(' and c != ')' and c != '#');
    }
}

test "round trip through parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const in: Fields = .{
        .id = "261021042815-k7qp",
        .project = "a b(c)?d&e#f%g/h",
        .title = "t [x] = (y) + z",
        .dir = "/p q/ø/日本",
        .window = "w&w",
    };
    const target = try testTarget(in);
    defer std.testing.allocator.free(target);
    const out = try parse(arena.allocator(), target);
    inline for (.{ "id", "project", "title", "dir", "window" }) |name| {
        try std.testing.expectEqualStrings(@field(in, name).?, @field(out, name).?);
    }
}

test "parse: empty and missing fields are null" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out = try parse(arena.allocator(), "GHO:?id=abc&title=&bogus=1#frag");
    try std.testing.expect(out.project == null);
    try std.testing.expectEqualStrings("abc", out.id.?);
    try std.testing.expect(out.title == null);
    try std.testing.expect(out.dir == null);
    try std.testing.expect(out.window == null);
}

test "parse: errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.NotATabLink, parse(a, "pedit:x?id=1"));
    try std.testing.expectError(error.NotATabLink, parse(a, "gh"));
    try std.testing.expectError(error.InvalidEncoding, parse(a, "gho:?id=%4"));
    try std.testing.expectError(error.InvalidEncoding, parse(a, "gho:?id=%zz"));
    try std.testing.expectError(error.InvalidEncoding, parse(a, "gho:?id=a%00b"));
}

test "write a link escapes the label" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeLink(&buf.writer, "a [b] \\c\nd", .{ .id = "x" });
    try std.testing.expectEqualStrings("[gho:a \\[b\\] \\\\c d](gho:?id=x)", buf.written());
}

test "write an id" {
    var prng: std.Random.DefaultPrng = .init(1);
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try writeId(&buf.writer, "261021042815", prng.random());
    try std.testing.expectEqual(id_len, buf.written().len);
    try std.testing.expectEqualStrings("261021042815-", buf.written()[0..13]);
}
