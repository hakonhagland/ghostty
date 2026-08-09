//! Per-project colours, shared by the tab bar and the command palette.
//!
//! A project keeps the same colour everywhere it appears, and across restarts,
//! because the colour is derived from the name rather than assigned. That is
//! the whole point: a colour you have to remember is worse than no colour.
//!
//! Two consumers need two different forms of the same choice. The palette rows
//! are text, so they take a CSS class and let the stylesheet pick the shade for
//! the current theme. The tab bar swatch is an SVG image, which cannot consult
//! the stylesheet, so it needs a literal colour and has to be told whether the
//! theme is dark. Keeping both here is what stops them drifting apart.

const std = @import("std");

/// The number of colours in the palette. Must match the `#project-N` rules in
/// `css/style.css` and its dark and high-contrast variants.
pub const count: u64 = 8;

/// Light-theme values, matching `css/style.css`.
const light: [count][3]u8 = .{
    .{ 0x1c, 0x71, 0xd8 },
    .{ 0x00, 0x88, 0x7a },
    .{ 0x1b, 0x8c, 0x3f },
    .{ 0x8f, 0x68, 0x00 },
    .{ 0xb3, 0x54, 0x1e },
    .{ 0xc0, 0x1c, 0x28 },
    .{ 0xa2, 0x25, 0x8f },
    .{ 0x72, 0x39, 0xb3 },
};

/// Dark-theme values, matching `css/style-dark.css`.
const dark: [count][3]u8 = .{
    .{ 0x78, 0xae, 0xed },
    .{ 0x4d, 0xd8, 0xc4 },
    .{ 0x78, 0xe0, 0x8f },
    .{ 0xf8, 0xe4, 0x5c },
    .{ 0xff, 0xbe, 0x6f },
    .{ 0xff, 0x93, 0x8c },
    .{ 0xff, 0x9a, 0xe3 },
    .{ 0xdc, 0x8a, 0xdd },
};

/// Which of the `count` colours this project gets.
///
/// FNV-1a. Any stable hash would do; what matters is that the same name always
/// lands on the same colour, on this machine and on any other.
pub fn index(project: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (project) |b| {
        hash ^= b;
        hash *%= 0x100000001b3;
    }
    return hash % count;
}

/// The CSS class carrying this project's colour, e.g. `project-3`.
pub fn cssClass(project: []const u8) [:0]const u8 {
    return switch (index(project)) {
        0 => "project-0",
        1 => "project-1",
        2 => "project-2",
        3 => "project-3",
        4 => "project-4",
        5 => "project-5",
        6 => "project-6",
        else => "project-7",
    };
}

/// This project's colour as RGB, for callers that cannot use CSS.
pub fn rgb(project: []const u8, is_dark: bool) [3]u8 {
    const i = index(project);
    return if (is_dark) dark[i] else light[i];
}

test "a project always gets the same colour" {
    const testing = std.testing;

    try testing.expectEqualStrings(cssClass("ghostty"), cssClass("ghostty"));
    try testing.expectEqual(rgb("ghostty", false), rgb("ghostty", false));

    // The CSS class and the literal colour must agree on which slot they mean,
    // or a project reads as one colour in the palette and another in the tab
    // bar — which is worse than having no colour at all.
    const i = index("ghostty");
    try testing.expectEqual(light[i], rgb("ghostty", false));
    try testing.expectEqual(dark[i], rgb("ghostty", true));
    try testing.expect(std.mem.endsWith(
        u8,
        cssClass("ghostty"),
        &.{'0' + @as(u8, @intCast(i))},
    ));
}

test "the palette is fully reachable" {
    const testing = std.testing;

    // Assert something about the hash rather than about a hand-picked word
    // list: over a couple of hundred names every slot should come up, and none
    // should be wildly over-represented. A first version of this test listed
    // sixteen realistic project names and failed — which said nothing about the
    // hash, only that sixteen samples do not cover eight buckets.
    var hits: [count]usize = @splat(0);
    var buf: [16]u8 = undefined;
    for (0..200) |i| {
        const name = std.fmt.bufPrint(&buf, "project-{d}", .{i}) catch unreachable;
        hits[index(name)] += 1;
    }

    for (hits) |n| {
        try testing.expect(n > 0);
        // Uniform would be 25. Anything past double that is not a hash.
        try testing.expect(n < 50);
    }
}
