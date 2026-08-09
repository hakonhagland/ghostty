const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const apprt = @import("../../../apprt.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const project_color = @import("../project_color.zig");

const log = std.log.scoped(.gtk_ghostty_window);

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"split-tree" = struct {
            pub const name = "split-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*SplitTree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*SplitTree,
                        .{
                            .getter = getSplitTree,
                        },
                    ),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
                },
            );
        };

        pub const tooltip = struct {
            pub const name = "tooltip";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("tooltip"),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };
        /// The project this tab belongs to, if any. Purely a user-assigned
        /// label; nothing derives it.
        pub const project = struct {
            pub const name = "project";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("project"),
                },
            );
        };

        /// Roughly how many characters of title this tab can show before the
        /// tab bar's fading label starts eating the end of it. Zero means
        /// "unknown, don't shorten". See `Window.updateTabTitleBudget`.
        pub const @"title-budget" = struct {
            pub const name = "title-budget";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "title_budget",
                    ),
                },
            );
        };

        pub const @"title-override" = struct {
            pub const name = "title-override";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title_override"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tab would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The title of this tab. This is usually bound to the active surface.
        title: ?[:0]const u8 = null,

        /// The manually overridden title.
        title_override: ?[:0]const u8 = null,

        /// The project this tab belongs to, from `promptTabProject` or from
        /// the `@project` prefix accepted by the switcher.
        project: ?[:0]const u8 = null,

        /// How much room the title has, in characters. Set by the window from
        /// the tab bar's actual width divided by the number of tabs.
        title_budget: c_uint = 0,

        /// The tooltip of this tab. This is usually bound to the active surface.
        tooltip: ?[:0]const u8 = null,

        // Template bindings
        split_tree: *SplitTree,

        pub var offset: c_int = 0;
    };

    /// Set the parent of this tab page. This only affects the first surface
    /// ever created for a tab. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        self.setParentWithContext(parent, .tab);
    }

    pub fn setParentWithContext(self: *Self, parent: *CoreSurface, context: apprt.surface.NewSurfaceContext) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent, context);
        }
    }

    pub fn new(config: ?*Config, overrides: struct {
        command: ?configpkg.Command = null,
        shell_integration: ?configpkg.Config.ShellIntegration = null,
        working_directory: ?[:0]const u8 = null,
        title: ?[:0]const u8 = null,

        pub const none: @This() = .{};
    }) *Self {
        const tab = gobject.ext.newInstance(Tab, .{});

        const priv: *Private = tab.private();

        if (config) |c| priv.config = c.ref();

        // If our configuration is null then we get the configuration
        // from the application.
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        tab.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Create our initial surface in the split tree.
        priv.split_tree.newSplit(.right, null, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        }) catch |err| switch (err) {
            error.OutOfMemory => {
                // TODO: We should make our "no surfaces" state more aesthetically
                // pleasing and show something like an "Oops, something went wrong"
                // message. For now, this is incredibly unlikely.
                @panic("oom");
            },
        };

        return tab;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Init our actions
        self.initActionMap();
    }

    fn initActionMap(self: *Self) void {
        const s_param_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_param_type.free();

        const actions = [_]ext.actions.Action(Self){
            .init("close", actionClose, s_param_type),
            .init("ring-bell", actionRingBell, null),
            .init("next-page", actionNextPage, null),
            .init("previous-page", actionPreviousPage, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-tab-project", actionPromptTabProject, null),
        };

        _ = ext.actions.addAsGroup(Self, self, "tab", &actions);
    }

    //---------------------------------------------------------------
    // Properties

    /// Overridden title. This will be generally be shown over the title
    /// unless this is unset (null).
    /// The manually set title for this tab, if the user has set one. This is
    /// only the user's own text; it is never the terminal-reported title.
    pub fn getTitleOverride(self: *Self) ?[:0]const u8 {
        return self.private().title_override;
    }

    /// The project this tab belongs to, if the user has assigned one.
    pub fn getProject(self: *Self) ?[:0]const u8 {
        return self.private().project;
    }

    /// Set how many characters of title this tab can show. Recomputed on every
    /// resize, so the early return matters: without it every pixel of a drag
    /// would rebuild every tab's title string.
    pub fn setTitleBudget(self: *Self, budget: c_uint) void {
        const priv = self.private();
        if (priv.title_budget == budget) return;
        priv.title_budget = budget;
        self.as(gobject.Object).notifyByPspec(properties.@"title-budget".impl.param_spec);
    }

    pub fn setProject(self: *Self, project: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.project) |v| glib.free(@ptrCast(@constCast(v)));
        priv.project = null;
        if (project) |v| {
            if (v.len > 0) priv.project = glib.ext.dupeZ(u8, v);
        }
        self.as(gobject.Object).notifyByPspec(properties.project.impl.param_spec);
    }

    /// A coloured dot identifying this tab's project, or null if it has none.
    ///
    /// `AdwTabPage:icon` is a `GIcon` rather than a themed icon name, so it
    /// accepts an arbitrary image — which is the only way colour reaches the
    /// tab bar at all. A symbolic icon would not do: GTK recolours those to the
    /// foreground colour, so every project would come out the same hue.
    ///
    /// The pixels are built here rather than handed over as an SVG in a
    /// `GBytesIcon`. That was the first attempt and it **segfaults**: GTK routes
    /// encoded image bytes through glycin, which calls into fontconfig, which
    /// dies inside a process already using fontconfig for its own font
    /// discovery. A `GdkMemoryTexture` implements `GIcon` directly and runs no
    /// decoder at all, so nothing but our own bytes is involved.
    ///
    /// The caller owns the returned reference.
    pub fn projectIcon(self: *Self) ?*gio.Icon {
        const project = self.private().project orelse return null;
        if (project.len == 0) return null;

        // The stylesheet is not reachable from raw pixels, so the theme has to
        // be asked directly and the icon rebuilt when it changes.
        const colour = project_color.rgb(
            project,
            adw.StyleManager.getDefault().getDark() != 0,
        );

        const size = 16;
        const radius: f32 = 5;
        const centre: f32 = (size - 1) / 2;

        // Premultiplied, so each channel is scaled by coverage along with the
        // alpha; writing unpremultiplied values here produces a dark halo.
        var px: [size * size * 4]u8 = undefined;
        for (0..size) |y| {
            for (0..size) |x| {
                const dx = @as(f32, @floatFromInt(x)) - centre;
                const dy = @as(f32, @floatFromInt(y)) - centre;
                const d = @sqrt(dx * dx + dy * dy);

                // One pixel of feathering at the rim. Without it a 16px circle
                // reads as a jagged blob at this size.
                const coverage = std.math.clamp(radius - d + 0.5, 0, 1);

                const i = (y * size + x) * 4;
                px[i + 0] = @intFromFloat(@as(f32, @floatFromInt(colour[0])) * coverage);
                px[i + 1] = @intFromFloat(@as(f32, @floatFromInt(colour[1])) * coverage);
                px[i + 2] = @intFromFloat(@as(f32, @floatFromInt(colour[2])) * coverage);
                px[i + 3] = @intFromFloat(255 * coverage);
            }
        }

        const bytes = glib.Bytes.new(&px, px.len);
        defer bytes.unref();
        const texture = gdk.MemoryTexture.new(
            size,
            size,
            .r8g8b8a8_premultiplied,
            bytes,
            size * 4,
        );
        return texture.as(gio.Icon);
    }

    pub fn setTitleOverride(self: *Self, title: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.title_override) |v| glib.free(@ptrCast(@constCast(v)));
        priv.title_override = null;
        if (title) |v| priv.title_override = glib.ext.dupeZ(u8, v);
        self.as(gobject.Object).notifyByPspec(properties.@"title-override".impl.param_spec);
    }
    fn titleDialogSet(
        _: *TitleDialog,
        title_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const typed = std.mem.span(title_ptr);
        if (typed.len == 0) {
            self.setTitleOverride(null);
            return;
        }

        // The `project:name` shorthand used to be accepted here. It has been
        // retired: `Ctrl+P` sets a project directly, and the new terminal
        // dialog names the field outright, so the shorthand only survived as a
        // second convention to learn — and one that made a colon in a title
        // mean something. A title is now just a title.
        self.setTitleOverride(typed);
    }

    fn projectDialogSet(
        _: *TitleDialog,
        project_ptr: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const project = std.mem.span(project_ptr);
        self.setProject(if (project.len == 0) null else project);
    }

    pub fn promptTabProject(self: *Self) void {
        const dialog = TitleDialog.new(.project, self.private().project);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            projectDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }
    pub fn promptTabTitle(self: *Self) void {
        const priv = self.private();
        const dialog = TitleDialog.new(.tab, priv.title_override orelse priv.title);
        _ = TitleDialog.signals.set.connect(
            dialog,
            *Self,
            titleDialogSet,
            self,
            .{},
        );

        dialog.present(self.as(gtk.Widget));
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        return self.getSplitTree().getActiveSurface();
    }

    /// Get the surface tree of this tab.
    pub fn getSurfaceTree(self: *Self) ?*Surface.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget that is in this tab.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    /// Returns true if this tab needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tree = self.getSplitTree();
        return tree.getNeedsConfirmQuit();
    }

    /// Get the tab view holding this tab, if any.
    fn getTabView(self: *Self) ?*adw.TabView {
        return ext.getAncestor(
            adw.TabView,
            self.as(gtk.Widget),
        );
    }

    /// Get the tab page holding this tab, if any.
    fn getTabPage(self: *Self) ?*adw.TabPage {
        const tab_view = self.getTabView() orelse return null;
        return tab_view.getPage(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tooltip) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tooltip = null;
        }
        if (priv.title) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title = null;
        }
        if (priv.project) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.project = null;
        }
        if (priv.title_override) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.title_override = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the tab.
        const tree: *const Surface.Tree = self.getSurfaceTree() orelse &.empty;
        if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    fn actionClose(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("tab.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const tab_view = self.getTabView() orelse return;
        const page = tab_view.getPage(self.as(gtk.Widget));

        const mode = std.meta.stringToEnum(
            apprt.action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to tab.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            // Need to be defensive here since actions can be triggered externally.
            log.warn("invalid mode provided to tab.close-tab: {s}", .{str.?});
            return;
        };

        // Delegate to our parent to handle this, since this will emit
        // a close-page signal that the parent can intercept.
        switch (mode) {
            .this => tab_view.closePage(page),
            .other => tab_view.closeOtherPages(page),
            .right => tab_view.closePagesAfter(page),
        }
    }

    fn actionPromptTabProject(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptTabProject();
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.promptTabTitle();
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        // Future note: I actually don't like this logic living here at all.
        // I think a better approach will be for the ring bell action to
        // specify its sending surface and then do all this in the window.

        // If the page is selected already we don't mark it as needing
        // attention. We only want to mark unfocused pages. This will then
        // clear when the page is selected.
        const page = self.getTabPage() orelse return;
        if (page.getSelected() != 0) return;
        page.setNeedsAttention(@intFromBool(true));
    }

    /// Select the next tab page.
    fn actionNextPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectNextPage();
    }

    /// Select the previous tab page.
    fn actionPreviousPage(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const tab_view = self.getTabView() orelse return;
        _ = tab_view.selectPreviousPage();
    }

    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        terminal_: ?[*:0]const u8,
        surface_override_: ?[*:0]const u8,
        tab_override_: ?[*:0]const u8,
        project_: ?[*:0]const u8,
        budget_: c_uint,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the manually tab overridden title if it exists,
        // otherwise the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = tab_override_ orelse
                surface_override_ orelse
                terminal_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        // Prefix the project, so that the tab bar and the window title both
        // say which project a terminal belongs to. It is written first but
        // measured first too, since it eats into what the path has left.
        const project: []const u8 = project: {
            const p = project_ orelse break :project "";
            break :project std.mem.span(p);
        };
        if (project.len > 0) {
            buf.writer.print("[{s}] ", .{project}) catch {};
        }

        // Whatever the prefixes above have already consumed comes off the
        // budget before the path gets to use it.
        const spent = buf.written().len;
        // Zero is the "unknown" sentinel, so never let a prefix that ate the
        // whole budget produce one — that would read as "don't shorten" when
        // it means the opposite.
        const budget: usize = if (budget_ == 0) 0 else b: {
            const total: usize = @intCast(budget_);
            break :b @max(1, total -| spent);
        };

        buf.writer.writeAll(fitPath(plain, budget)) catch
            return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
    }

    /// Trim a path-like title from the front until it fits `budget`
    /// characters, dropping one leading component at a time. The tab bar's
    /// fading label eats the *end* of a title, which is the part that
    /// identifies the directory, so the front is what we can afford to lose.
    ///
    /// The leading `/` of whatever survives is left in place — it reads as a
    /// marker that something was cut. The last component is never dropped: a
    /// title trimmed to nothing identifies less than one that overflows.
    ///
    /// A budget of zero means "don't know", which happens before the tab bar
    /// has been allocated a width. Anything that does not look like a path is
    /// left alone, since a running command is not made clearer by chopping its
    /// front off.
    fn fitPath(title: []const u8, budget: usize) []const u8 {
        if (budget == 0) return title;
        if (title.len <= budget) return title;
        if (title[0] != '/' and title[0] != '~') return title;

        // Walk separators left to right and stop at the first cut that fits,
        // since cutting further would throw away context for nothing. If none
        // fits we end up at the last separator, which is the leaf — the one
        // component always worth keeping.
        //
        // Separators before index 2 are skipped: cutting there turns `~/x`
        // into `/x`, which saves one character and loses the distinction
        // between home and root.
        var last_fit: ?usize = null;
        var i: usize = 2;
        while (i < title.len) : (i += 1) {
            if (title[i] != '/') continue;
            last_fit = i;
            if (title.len - i <= budget) break;
        }

        const idx = last_fit orelse return title;
        return title[idx..];
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"split-tree".impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.@"title-budget".impl,
                properties.project.impl,
                properties.@"title-override".impl,
                properties.tooltip.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});

            // Template Callbacks
            class.bindTemplateCallback("computed_title", &closureComputedTitle);
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

            // Signals
            signals.@"close-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

test "fitPath" {
    const testing = std.testing;
    const path = "/home/hakon/git/research/custom-terminal";

    // Unknown budget, and budgets the title already fits, change nothing.
    try testing.expectEqualStrings(path, Tab.fitPath(path, 0));
    try testing.expectEqualStrings(path, Tab.fitPath(path, path.len));
    try testing.expectEqualStrings(path, Tab.fitPath(path, path.len + 10));

    // Drop only as many leading components as the budget demands.
    try testing.expectEqualStrings(
        "/hakon/git/research/custom-terminal",
        Tab.fitPath(path, 35),
    );
    try testing.expectEqualStrings(
        "/git/research/custom-terminal",
        Tab.fitPath(path, 30),
    );
    try testing.expectEqualStrings(
        "/research/custom-terminal",
        Tab.fitPath(path, 25),
    );

    // The leaf survives a budget that cannot hold it.
    try testing.expectEqualStrings(
        "/custom-terminal",
        Tab.fitPath(path, 5),
    );

    // A two-component path has nothing to give up.
    try testing.expectEqualStrings("~/Downloads", Tab.fitPath("~/Downloads", 4));

    // Non-paths are left alone: chopping the front off a command makes it
    // less identifiable, not more.
    try testing.expectEqualStrings(
        "npm run build --watch",
        Tab.fitPath("npm run build --watch", 5),
    );
    try testing.expectEqualStrings("", Tab.fitPath("", 5));
}
