const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const input = @import("../../../input.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const WeakRef = @import("../weak_ref.zig").WeakRef;
const project_color = @import("../project_color.zig");
const NewTerminalDialog = @import("new_terminal_dialog.zig").NewTerminalDialog;
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Window = @import("window.zig").Window;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_command_palette);

/// Replace the home directory prefix with "~" for display, matching what the
/// macOS palette does for its own entries.
fn abbreviateHome(alloc: Allocator, path: []const u8) ?[:0]const u8 {
    const home = std.mem.span(glib.getHomeDir());
    if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
        return std.fmt.allocPrintSentinel(alloc, "~{s}", .{path[home.len..]}, 0) catch null;
    }
    return alloc.dupeZ(u8, path) catch null;
}

pub const CommandPalette = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommandPalette",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
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
    };

    pub const signals = struct {
        /// Emitted when a command from the command palette is activated. The
        /// action contains pointers to allocated data so if a receiver of this
        /// signal needs to keep the action around it will need to clone the
        /// action or there may be use-after-free errors.
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const input.Binding.Action},
                void,
            );
        };
    };

    /// What the palette shows.
    pub const Mode = enum {
        /// Everything: the open terminals plus the configured commands.
        all,

        /// Only the open terminals. Used for switching between terminals
        /// without the configured commands in the way.
        jump,

        /// Only the configured keybindings, searchable by action or by the
        /// keys themselves. `ghostty +list-keybinds` prints the same thing,
        /// but only from a terminal.
        keybinds,
    };

    const Private = struct {
        /// The configuration that this command palette is using.
        config: ?*Config = null,

        /// What this palette is currently showing.
        mode: Mode = .all,

        /// The dialog object containing the palette UI.
        dialog: *adw.Dialog,

        /// The search input text field.
        search: *gtk.SearchEntry,

        /// The view containing each result row.
        view: *gtk.ListView,

        /// The filter deciding which rows the query matches. Owned by the
        /// template; the match function is installed in `init`.
        filter: *gtk.CustomFilter,

        /// The model that provides filtered data for the view to display.
        model: *gtk.SingleSelection,

        /// The list that serves as the data source of the model.
        /// This is where all command data is ultimately stored.
        source: *gio.ListStore,

        /// The footer listing the session search shortcuts.
        hints: *gtk.Label,

        /// The tab whose rename we are waiting on, and the handler watching
        /// it. The tab outlives the palette, so this must be disconnected in
        /// dispose or the callback would run against freed memory.
        rename_tab: WeakRef(Tab) = .empty,
        rename_handler: c_ulong = 0,

        /// The synthetic "create a terminal" row, when the query is non-empty
        /// in jump mode. Kept here so it can be replaced as the query changes.
        create_cmd: ?*Command = null,

        /// The window this palette was last presented over, which is where a
        /// newly created terminal goes.
        window: WeakRef(Window) = .empty,

        pub var offset: c_int = 0;
    };

    /// Create a new instance of the command palette. The caller will own a
    /// reference to the object.
    pub fn new() *Self {
        const self = gobject.ext.newInstance(Self, .{});

        // Sink ourselves so that we aren't floating anymore. We'll unref
        // ourselves when the palette is closed or an action is activated.
        _ = self.refSink();

        // Bump the ref so that the caller has a reference.
        return self.ref();
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        self.private().filter.setFilterFunc(
            filterMatch,
            self,
            null,
        );

        // Listen for any changes to our config.
        _ = gobject.Object.signals.notify.connect(
            self,
            ?*anyopaque,
            propConfig,
            null,
            .{
                .detail = "config",
            },
        );

        // Keep the selection on the best match as the query changes. See
        // `resetSelection` for why this is needed.
        _ = gtk.SearchEntry.signals.search_changed.connect(
            self.private().search,
            *Self,
            resetSelection,
            self,
            .{},
        );

        // Shortcuts for the session search. This is on the dialog in the
        // capture phase rather than on the entry so that it still works once
        // focus has moved into the result list.
        const keys = gtk.EventControllerKey.new();
        keys.as(gtk.EventController).setPropagationPhase(.capture);
        _ = gtk.EventControllerKey.signals.key_pressed.connect(
            keys,
            *Self,
            keyPressed,
            self,
            .{},
        );
        self.private().dialog.as(gtk.Widget).addController(keys.as(gtk.EventController));
    }

    fn keyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        state: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();

        // Arrow-key navigation applies in **both** modes. F4 restored the plain
        // palette to be pixel-identical to upstream and gated every key here on
        // the session search; that was right for the shortcuts below, which add
        // behaviour upstream does not have, but wrong for this. Two dialogs that
        // look the same and answer the arrow keys differently is a worse
        // surprise than either behaviour on its own.
        //
        // Drive the selection ourselves rather than letting GTK move focus
        // into the list.
        //
        // Left to itself, the first Down moves *focus* from the entry into the
        // list without moving the selection, so it appears to do nothing and
        // the second press is the one that moves. Hover makes it worse, since
        // it moves the selection independently, so the focus ring and the
        // highlight end up on different rows.
        //
        // Keeping focus in the entry the whole time means one press always
        // moves one row, from wherever the selection currently is, and typing
        // never stops working. This is how quick-open pickers generally
        // behave.
        if (!state.control_mask) {
            const down = keyval == gdk.KEY_Down or keyval == gdk.KEY_KP_Down;
            const up = keyval == gdk.KEY_Up or keyval == gdk.KEY_KP_Up;
            if (!down and !up) return 0;

            const n = priv.model.as(gio.ListModel).getNItems();
            if (n == 0) return 1;

            const current = priv.model.getSelected();

            // An unset selection counts as "before the first row", so the
            // first Down lands on the top row rather than the second.
            const next: c_uint = if (current == gtk.INVALID_LIST_POSITION)
                0
            else if (down)
                @min(current + 1, n - 1)
            else if (current == 0) 0 else current - 1;

            priv.model.setSelected(next);
            priv.view.scrollTo(next, .{}, null);
            return 1;
        }

        // Everything below is session-search behaviour that the plain palette
        // deliberately does not have.
        if (priv.mode != .jump) return 0;

        const is_return = keyval == gdk.KEY_Return or
            keyval == gdk.KEY_KP_Enter or
            keyval == gdk.KEY_ISO_Enter;

        if (is_return) {
            const window = priv.window.get() orelse return 0;
            defer window.unref();

            // Shift turns the fast path into the deliberate one. Ctrl+Enter
            // exists to skip deliberation entirely, so the dialog is a
            // separate binding rather than something imposed on it.
            if (state.shift_mask) {
                self.promptNewTerminal();
                return 1;
            }

            self.close();
            window.newTabUntitled();
            return 1;
        }

        if (keyval == gdk.KEY_p or keyval == gdk.KEY_P) {
            const tab = self.selectedTab() orelse return 0;
            self.watchRename(tab);
            tab.promptTabProject();
            return 1;
        }

        if (keyval == gdk.KEY_r or keyval == gdk.KEY_R) {
            const tab = self.selectedTab() orelse return 0;

            self.watchRename(tab);

            // Deliberately does *not* close the palette. Renaming is something
            // you discover you need part way through switching, so you should
            // land back in the list afterwards and be able to carry on with
            // what you originally opened it for.
            tab.promptTabTitle();
            return 1;
        }

        return 0;
    }

    /// Watch a tab for its title or project changing, so the row can be
    /// re-rendered under the user while the palette stays open.
    fn watchRename(self: *Self, tab: *Tab) void {
        const priv = self.private();
        self.disconnectRename();
        priv.rename_handler = gobject.Object.signals.notify.connect(
            tab,
            *Self,
            tabRenamed,
            self,
            .{},
        );
        priv.rename_tab.set(tab);
    }

    fn tabRenamed(tab: *Tab, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        defer self.disconnectRename();

        // Re-render just the affected rows rather than rebuilding the list.
        // A rebuild would re-sort, and since the rename dialog has taken the
        // focus away the recency order comes back different, so the row the
        // user is looking at would jump somewhere else mid-task.
        const n = priv.source.as(gio.ListModel).getNItems();
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const object = priv.source.as(gio.ListModel).getObject(i) orelse continue;
            defer object.unref();

            const cmd = gobject.ext.cast(Command, object) orelse continue;
            const surface = cmd.getJumpSurface() orelse continue;
            defer surface.unref();

            const owner = ext.getAncestor(Tab, surface.as(gtk.Widget)) orelse continue;
            if (owner != tab) continue;

            cmd.invalidateTitle();
        }
    }

    fn disconnectRename(self: *Self) void {
        const priv = self.private();
        if (priv.rename_handler == 0) return;

        if (priv.rename_tab.get()) |tab| {
            defer tab.unref();
            gobject.signalHandlerDisconnect(
                tab.as(gobject.Object),
                priv.rename_handler,
            );
        }

        priv.rename_handler = 0;
        priv.rename_tab.set(null);
    }

    /// The tab owning the currently selected row, if that row is a terminal.
    fn selectedTab(self: *Self) ?*Tab {
        const priv = self.private();

        const object = priv.model.as(gio.ListModel).getObject(
            priv.model.getSelected(),
        ) orelse return null;
        defer object.unref();

        const cmd = gobject.ext.cast(Command, object) orelse return null;
        const surface = cmd.getJumpSurface() orelse return null;
        defer surface.unref();

        return ext.getAncestor(Tab, surface.as(gtk.Widget));
    }

    /// Move the selection back to the first row.
    ///
    /// The list view is `single-click-activate`, which GTK documents as
    /// "activate rows on single click and select them on hover". Hover
    /// therefore moves the *selection*, not just the highlight, and Enter
    /// activates the selection. A pointer left resting anywhere over the list
    /// silently hijacks what Enter does, including across a change of query
    /// that reorders the results underneath it.
    ///
    /// Re-selecting the first row whenever the query changes keeps the
    /// keyboard path predictable: after typing, Enter always activates the
    /// best match.
    fn resetSelection(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        self.private().model.setSelected(0);
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // You MUST clear every weak ref here. The target keeps a pointer to the
        // GWeakRef itself, and finalizing the target walks that list and takes
        // a lock inside each entry — so if this object's memory has been freed
        // by then, the target locks whatever now occupies it and can block
        // forever. `inspector_window.zig` carries the same warning.
        //
        // disconnectRename clears rename_tab too, but only when a handler is
        // connected. Clearing it here as well costs nothing and removes the
        // dependence on that pairing holding forever.
        self.disconnectRename();
        priv.window.set(null);
        priv.rename_tab.set(null);
        priv.source.removeAll();

        if (priv.config) |config| {
            config.unref();
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

    //---------------------------------------------------------------
    // Signal Handlers

    /// Set what this palette shows. Repopulating is deferred until we have a
    /// config, so that this can be called immediately after construction
    /// without tripping the "no config" warning below.
    pub fn setMode(self: *CommandPalette, mode: Mode) void {
        const priv = self.private();
        if (priv.mode == mode) return;
        priv.mode = mode;
        if (priv.config != null) {
            priv.search.as(gtk.Editable).setText("");
            self.refresh();
        }
    }

    fn propConfig(self: *CommandPalette, _: *gobject.ParamSpec, _: ?*anyopaque) callconv(.c) void {
        self.refresh();
    }

    fn refresh(self: *CommandPalette) void {
        const priv = self.private();

        const config = priv.config orelse {
            log.warn("command palette does not have a config!", .{});
            return;
        };

        // The placeholder tells the user what this invocation will search.
        // The placeholder is where `@project` gets discovered: it is visible
        // before anything has been typed, which is exactly when someone is
        // wondering what the box accepts. The footer is already full.
        priv.search.setPlaceholderText(switch (priv.mode) {
            .all => i18n._("Execute a command…"),
            .jump => i18n._("Switch to a terminal, or @project…"),
            .keybinds => i18n._("Search keybindings by action or by key…"),
        });

        // The session search has shortcuts that nothing else advertises, so
        // spell them out. The plain palette has none, so it gets no footer.
        const show_hints = priv.mode == .jump;
        priv.hints.as(gtk.Widget).setVisible(@intFromBool(show_hints));
        if (show_hints) priv.hints.setLabel(
            i18n._("Enter switch · Ctrl+Enter new · Ctrl+Shift+Enter new… · Ctrl+R rename · Ctrl+P project"),
        );

        // Clear existing binds
        priv.source.removeAll();
        if (priv.create_cmd) |cmd| {
            cmd.unref();
            priv.create_cmd = null;
        }

        const alloc = Application.default().allocator();
        var commands: std.ArrayList(*Command) = .empty;
        defer {
            for (commands.items) |cmd| cmd.unref();
            commands.deinit(alloc);
        }

        if (priv.mode == .keybinds) {
            self.collectKeybindCommands(config, &commands, alloc);
        } else {
            self.collectJumpCommands(config, &commands) catch |err| {
                log.warn("failed to collect jump commands: {}", .{err});
            };

            if (priv.mode == .all) self.collectRegularCommands(config, &commands, alloc);
        }

        // Sort commands
        std.mem.sort(*Command, commands.items, {}, struct {
            fn lessThan(_: void, a: *Command, b: *Command) bool {
                return compareCommands(a, b);
            }
        }.lessThan);

        // The most recently used surface is the one we are sitting in right
        // now, and jumping to where you already are is never what you want.
        // Demote it by one so that the entry under the cursor on open is the
        // last place you were.
        //
        // This is a post-sort fixup rather than a rule in the comparator
        // because "the focused entry sorts second" is not a strict weak
        // ordering, and an ill-formed comparator is not safe to hand to sort.
        if (priv.mode == .jump and commands.items.len >= 2) demote: {
            const first = commands.items[0];
            if (!first.isJump()) break :demote;
            if (!commands.items[1].isJump()) break :demote;

            const surface = first.getJumpSurface() orelse break :demote;
            defer surface.unref();
            if (!surface.getFocused()) break :demote;

            std.mem.swap(*Command, &commands.items[0], &commands.items[1]);
        }

        for (commands.items) |cmd| {
            const cmd_ref = cmd.as(gobject.Object);
            priv.source.append(cmd_ref);
        }
    }

    /// Collect regular commands from configuration, filtering out unsupported actions.
    /// Build one row per configured keybinding.
    ///
    /// Sequences (leader keys) are skipped: a chord has no single trigger to
    /// print, and showing only its first key would be a lie about what is
    /// bound.
    fn collectKeybindCommands(
        _: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
        alloc: std.mem.Allocator,
    ) void {
        const cfg = config.get();
        var it = cfg.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            const leaf = switch (entry.value_ptr.*) {
                .leaf => |leaf| leaf,
                else => continue,
            };

            const cmd = Command.newKeybind(
                config,
                entry.key_ptr.*,
                leaf.action,
            ) catch |err| {
                log.warn("failed to build a keybind row: {}", .{err});
                continue;
            };

            commands.append(alloc, cmd) catch {
                cmd.unref();
                return;
            };
        }
    }

    fn collectRegularCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
        alloc: std.mem.Allocator,
    ) void {
        _ = self;
        const cfg = config.get();

        for (cfg.@"command-palette-entry".value.items) |command| {
            // Filter out actions that are not implemented or don't make sense
            // for GTK.
            if (!isActionSupportedOnGtk(command.action)) continue;

            const cmd = Command.new(config, command) catch |err| {
                log.warn("failed to create command: {}", .{err});
                continue;
            };
            errdefer cmd.unref();

            commands.append(alloc, cmd) catch |err| {
                log.warn("failed to add command to list: {}", .{err});
                continue;
            };
        }
    }

    /// Check if an action is supported on GTK.
    fn isActionSupportedOnGtk(action: input.Binding.Action) bool {
        return switch (action) {
            .close_all_windows,
            .toggle_secure_input,
            .check_for_updates,
            .redo,
            .undo,
            .reset_window_size,
            .toggle_window_float_on_top,
            => false,

            else => true,
        };
    }

    /// Collect jump commands for all surfaces across all windows.
    fn collectJumpCommands(
        self: *CommandPalette,
        config: *Config,
        commands: *std.ArrayList(*Command),
    ) !void {
        const plain = self.private().mode == .all;
        const app = Application.default();
        const alloc = app.allocator();

        // Get all surfaces from the core app
        const core_app = app.core();
        for (core_app.surfaces.items) |apprt_surface| {
            const surface = apprt_surface.gobj();
            const cmd = Command.newJump(config, surface, plain);
            errdefer cmd.unref();
            try commands.append(alloc, cmd);
        }
    }

    /// Compare two commands for sorting.
    ///
    /// Jump commands sort above all regular commands, and amongst themselves
    /// by most recently used first. The palette is opened to navigate between
    /// terminals far more often than to run a configured action, so the
    /// terminals belong at the top where they can be reached without typing.
    ///
    /// Regular commands sort alphabetically by title (case-insensitive), with
    /// colon normalization so "Foo:" sorts before "Foo Bar:".
    fn compareCommands(a: *Command, b: *Command) bool {
        // The synthetic create row always sorts last so that it never steals
        // the default selection from a real terminal.
        if (a.isCreate()) return false;
        if (b.isCreate()) return true;

        // In the session search, terminals sort most recently used first.
        // In the plain palette they keep upstream's behaviour and interleave
        // alphabetically with the configured commands, below.
        switch (a.private().data) {
            // Keybind rows only ever appear alongside other keybind rows, and
            // fall through to the alphabetical comparison below.
            .keybind => {},
            .jump => |*ja| switch (b.private().data) {
                .jump => |*jb| {
                    if (!ja.plain and !jb.plain) {
                        if (ja.sort_key == jb.sort_key) return false;
                        return ja.sort_key > jb.sort_key;
                    }
                },
                .regular => if (!ja.plain) return true,
                .create, .keybind => unreachable,
            },
            .regular => switch (b.private().data) {
                .jump => |*jb| if (!jb.plain) return false,
                .regular, .create, .keybind => {},
            },
            .create => unreachable,
        }

        const a_title = a.propGetTitle() orelse return false;
        const b_title = b.propGetTitle() orelse return true;

        // Compare case-insensitively with colon normalization
        for (0..@min(a_title.len, b_title.len)) |i| {
            // Get characters, replacing ':' with '\t'
            const a_char = if (a_title[i] == ':') '\t' else a_title[i];
            const b_char = if (b_title[i] == ':') '\t' else b_title[i];

            const a_lower = std.ascii.toLower(a_char);
            const b_lower = std.ascii.toLower(b_char);

            if (a_lower != b_lower) {
                return a_lower < b_lower;
            }
        }

        // If one title is a prefix of the other, shorter one comes first
        if (a_title.len != b_title.len) {
            return a_title.len < b_title.len;
        }

        // Both are regular commands with equal titles. Jump commands never
        // reach here; they are fully ordered by the switch above.
        return false;
    }

    fn close(self: *CommandPalette) void {
        const priv = self.private();
        _ = priv.dialog.close();
    }

    fn dialogClosed(_: *adw.Dialog, self: *CommandPalette) callconv(.c) void {
        self.unref();
    }

    /// Case-insensitive substring test, which is what every other quick-open
    /// picker means by "matches".
    fn contains(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
    }

    /// Decide whether one row passes the current query.
    ///
    /// `@project rest` narrows to terminals in a project whose name contains
    /// `project`, and then applies `rest` as an ordinary search within them.
    /// Both halves are optional: `@web` is every terminal in `web`, and a query
    /// with no sigil behaves exactly as it did before.
    fn filterMatch(item: *gobject.Object, ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 1));
        const priv = self.private();
        const cmd = gobject.ext.cast(Command, item) orelse return 1;

        const text = std.mem.span(priv.search.as(gtk.Editable).getText());
        const project_q, const rest = Window.parseQuery(text);

        // The create row *is* the query, so it always belongs in the list. It
        // used to stay visible by repeating the query in its own label, which
        // only worked while the filter was a plain substring match.
        if (cmd.isCreate()) return 1;

        if (project_q) |q| {
            // A project query is only meaningful for terminals.
            if (!cmd.isJump()) return 0;
            const project = cmd.propGetProject() orelse return 0;
            if (!contains(project, q)) return 0;
        }

        if (rest.len == 0) return 1;

        if (cmd.propGetTitle()) |title| {
            if (contains(title, rest)) return 1;
        }
        // The working directory is the subtitle once a terminal has been given
        // a name of its own, so without this a renamed terminal stops being
        // findable by where it is.
        if (cmd.propGetSubtitle()) |subtitle| {
            if (contains(subtitle, rest)) return 1;
        }
        if (cmd.propGetActionKey()) |action_key| {
            if (contains(action_key, rest)) return 1;
        }

        return 0;
    }

    fn searchChanged(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        self.syncCreateCommand();
        self.private().filter.as(gtk.Filter).changed(.different);
    }

    /// Keep the synthetic "create a terminal" row in step with the query.
    ///
    /// The row is offered whenever the query is non-empty, not only when
    /// nothing matches: otherwise you could never create "web" while
    /// "web-old" still matched. Its label repeats the query so that it keeps
    /// passing the search filter.
    fn syncCreateCommand(self: *CommandPalette) void {
        const priv = self.private();

        // Remove the previous one, if any. It is always the last entry, but
        // look it up properly rather than relying on that.
        if (priv.create_cmd) |cmd| {
            var pos: c_uint = 0;
            if (priv.source.find(cmd.as(gobject.Object), &pos) != 0) {
                priv.source.remove(pos);
            }
            cmd.unref();
            priv.create_cmd = null;
        }

        // Creating from the palette only makes sense when it is being used to
        // switch terminals.
        if (priv.mode != .jump) return;

        const config = priv.config orelse return;
        const text = std.mem.span(priv.search.as(gtk.Editable).getText());
        const query = std.mem.trim(u8, text, " ");
        if (query.len == 0) return;

        // A bare `@` is a sigil with nothing after it, so there is nothing to
        // create yet. Without this the row reads `Create terminal ""`.
        const parsed_project, const parsed_name = Window.parseQuery(query);
        if (parsed_project == null and parsed_name.len == 0) return;

        const cwd = if (priv.window.get()) |window| cwd: {
            defer window.unref();
            break :cwd window.newTabCwdFor(query);
        } else null;

        const cmd = Command.newCreate(config, query, cwd) catch |err| {
            log.warn("failed to create the create-terminal row: {}", .{err});
            return;
        };

        priv.create_cmd = cmd;
        priv.source.append(cmd.as(gobject.Object));
    }

    /// Open the new terminal dialog, prefilled from the query and from what is
    /// selected.
    ///
    /// Deliberately does *not* close the palette. Cancelling should land you
    /// back in the list you were looking at — you were narrowing towards
    /// something, and being thrown out of the switcher for changing your mind
    /// costs the whole search. The palette closes only once a terminal is
    /// actually created.
    fn promptNewTerminal(self: *Self) void {
        const priv = self.private();
        const window = priv.window.get() orelse return;
        defer window.unref();

        const text = std.mem.span(priv.search.as(gtk.Editable).getText());
        const typed_project, const name = Window.parseQuery(text);

        // A typed project is a *fragment* being narrowed with — `@f` on the way
        // to `foo`. Prefilling the dialog with `f` would put the fragment into
        // a field that is no longer being filtered, where it silently becomes a
        // real project name. The selected row already says which project the
        // fragment resolved to, so prefer that.
        const project: []const u8 = project: {
            if (self.selectedTab()) |tab| {
                if (tab.getProject()) |p| break :project p;
            }
            if (typed_project) |p| break :project p;
            break :project window.currentProject() orelse "";
        };

        const dialog = NewTerminalDialog.new(name, project);
        _ = NewTerminalDialog.signals.create.connect(
            dialog,
            *Self,
            newTerminalCreate,
            self,
            .{},
        );
        dialog.present(self.as(gtk.Widget));
    }

    fn newTerminalCreate(
        _: *NewTerminalDialog,
        name: [*:0]const u8,
        project: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        const window = self.private().window.get() orelse return;
        defer window.unref();

        self.close();
        window.newTabWith(std.mem.span(name), std.mem.span(project));
    }

    fn searchStopped(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // ESC was pressed - close the palette
        self.close();
    }

    fn searchActivated(_: *gtk.SearchEntry, self: *CommandPalette) callconv(.c) void {
        // If Enter is pressed, activate the selected entry
        const priv = self.private();
        self.activated(priv.model.getSelected());
    }

    fn rowActivated(_: *gtk.ListView, pos: c_uint, self: *CommandPalette) callconv(.c) void {
        self.activated(pos);
    }

    //---------------------------------------------------------------

    /// Show or hide the command palette dialog. If the dialog is shown it will
    /// be modal over the given window.
    pub fn toggle(self: *CommandPalette, window: *Window) void {
        const priv = self.private();

        // If the dialog has been shown, close it.
        if (priv.dialog.as(gtk.Widget).getRealized() != 0) {
            self.close();
            return;
        }

        // Remember where a newly created terminal should go.
        priv.window.set(window);

        // Show the dialog
        priv.dialog.present(window.as(gtk.Widget));

        // Focus on the search bar when opening the dialog
        _ = priv.search.as(gtk.Widget).grabFocus();

        // If the pointer happens to be resting over the list as it appears,
        // hover selects that row (see `resetSelection`). That happens as the
        // list is mapped, which is after this point, so the correction has to
        // wait for the main loop to settle.
        _ = glib.idleAddOnce(idleResetSelection, self.ref());
    }

    /// Userdata is a `*CommandPalette`. Unrefs once.
    fn idleResetSelection(ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        self.private().model.setSelected(0);
    }

    /// Helper function to send a signal containing the action that should be
    /// performed.
    fn activated(self: *CommandPalette, pos: c_uint) void {
        const priv = self.private();

        // Use priv.model and not priv.source here to use the list of *visible* results
        const object_ = priv.model.as(gio.ListModel).getObject(pos);
        defer if (object_) |object| object.unref();

        // Close before running the action in order to avoid being replaced by
        // another dialog (such as the change title dialog). If that occurs then
        // the command palette dialog won't be counted as having closed properly
        // and cannot receive focus when reopened.
        self.close();

        const cmd = gobject.ext.cast(Command, object_ orelse return) orelse return;

        // Handle jump commands differently
        if (cmd.isJump()) {
            const surface = cmd.getJumpSurface() orelse return;
            defer surface.unref();
            surface.present();
            return;
        }

        // A keybind row is a listing, not something to run. Close, so that
        // Enter does something rather than appearing dead.
        if (priv.mode == .keybinds) {
            self.close();
            return;
        }

        // The synthetic create row opens the dialog rather than creating
        // straight away. Both fields are prefilled from the query, so
        // accepting is one Enter, and the fields are visible — which is the
        // only place the rules about naming are actually discoverable.
        // Ctrl+Enter remains the path that creates with no prompt at all.
        if (cmd.isCreate()) {
            self.promptNewTerminal();
            return;
        }

        // Regular command - emit trigger signal
        const action = cmd.getAction() orelse return;

        // Signal that an action has been selected. Signals are synchronous
        // so we shouldn't need to worry about cloning the action.
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.ext.ensureType(Command);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "command-palette",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("dialog", .{});
            class.bindTemplateChildPrivate("search", .{});
            class.bindTemplateChildPrivate("view", .{});
            class.bindTemplateChildPrivate("model", .{});
            class.bindTemplateChildPrivate("filter", .{});
            class.bindTemplateChildPrivate("source", .{});
            class.bindTemplateChildPrivate("hints", .{});

            // Template Callbacks
            class.bindTemplateCallback("closed", &dialogClosed);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("search_stopped", &searchStopped);
            class.bindTemplateCallback("search_activated", &searchActivated);
            class.bindTemplateCallback("row_activated", &rowActivated);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Signals
            signals.trigger.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Object that wraps around a command.
///
/// As GTK list models only accept objects that are within the GObject hierarchy,
/// we have to construct a wrapper to be easily consumed by the list model.
const Command = extern struct {
    pub const Self = @This();
    pub const Parent = gobject.Object;
    parent: Parent,

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyCommand",
        .instanceInit = &init,
        .classInit = Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const properties = struct {
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

        pub const action_key = struct {
            pub const name = "action-key";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetActionKey,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const action = struct {
            pub const name = "action";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetAction,
                            .getter_transfer = .none,
                        },
                    ),
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
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetTitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        pub const description = struct {
            pub const name = "description";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetDescription,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        /// The project a terminal belongs to, taken from the part of a
        /// manually set tab title before the first colon. Null for regular
        /// commands and for tabs with no manually set title.
        pub const project = struct {
            pub const name = "project";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetProject,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        /// The CSS class carrying this project's colour, e.g. "project-3".
        /// Assigned by hashing the name so a project keeps its colour across
        /// restarts with no configuration.
        pub const @"project-css" = struct {
            pub const name = "project-css";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetProjectCss,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };

        /// Whether `project` is set. Exists so that the row template can bind
        /// the project label's visibility without needing a closure.
        pub const @"has-project" = struct {
            pub const name = "has-project";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = propGetHasProject },
                    ),
                },
            );
        };

        /// The second line of a row: the keybind action for a regular command,
        /// or the working directory for a terminal.
        pub const subtitle = struct {
            pub const name = "subtitle";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?[:0]const u8,
                        .{
                            .getter = propGetSubtitle,
                            .getter_transfer = .none,
                        },
                    ),
                },
            );
        };
    };

    pub const Private = struct {
        config: ?*Config = null,
        arena: ArenaAllocator,
        data: CommandData,

        pub var offset: c_int = 0;

        pub const CommandData = union(enum) {
            regular: RegularData,
            jump: JumpData,
            create: CreateData,
            keybind: KeybindData,
        };

        /// One configured keybinding.
        pub const KeybindData = struct {
            /// The action, e.g. `toggle_command_palette`.
            action_name: [:0]const u8,

            /// The trigger as the config spells it, e.g. `ctrl+shift+p`. The
            /// filter matches this, which is the point: "what did I bind to
            /// ctrl+shift+p" is a search for the keys, not for the action.
            trigger: [:0]const u8,

            /// The same trigger as a GTK accelerator, for the ShortcutLabel.
            accel: ?[:0]const u8 = null,
        };

        /// A synthetic row offering to create a terminal named after whatever
        /// the user has typed so far.
        pub const CreateData = struct {
            /// The typed text, which becomes the new tab's title.
            query: [:0]const u8,

            /// The row label, e.g. `Create tab "web:server"`.
            title: ?[:0]const u8 = null,

            /// The directory the new terminal will start in, for display, so
            /// that the project inheritance rule is visible rather than a
            /// surprise.
            subtitle: ?[:0]const u8 = null,
        };

        pub const RegularData = struct {
            command: input.Command,
            action: ?[:0]const u8 = null,
            action_key: ?[:0]const u8 = null,
        };

        pub const JumpData = struct {
            surface: WeakRef(Surface) = .empty,
            title: ?[:0]const u8 = null,
            description: ?[:0]const u8 = null,

            /// Lazily computed and then cached, like `title`. `parsed` marks
            /// that the split has been attempted, since a null `project` is a
            /// legitimate result.
            project: ?[:0]const u8 = null,
            parsed: bool = false,

            /// The working directory, abbreviated for display.
            subtitle: ?[:0]const u8 = null,

            /// The surface's focus sequence, captured when this command was
            /// built. Higher means more recently used. Captured rather than
            /// read live so that the ordering cannot shift underneath the
            /// user while the palette is open.
            sort_key: u64,

            /// True when this entry is being shown in the plain command
            /// palette, where it behaves exactly as it did before the session
            /// search existed: a "Focus: " prefix and no project split.
            plain: bool = false,
        };
    };

    pub fn new(config: *Config, command: input.Command) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });
        errdefer self.unref();

        const priv = self.private();
        const cloned = try command.clone(priv.arena.allocator());

        priv.data = .{
            .regular = .{
                .command = cloned,
            },
        };

        return self;
    }

    /// Create the synthetic row that offers to create a terminal named
    /// after the current query.
    /// A row for one configured keybinding.
    pub fn newKeybind(
        config: *Config,
        trigger: input.Binding.Trigger,
        action: input.Binding.Action,
    ) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{ .config = config });
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();

        // The trigger in the config's own spelling — `ctrl+shift+p` — because
        // that is what someone types when they are looking for it.
        const trigger_text = try std.fmt.allocPrintSentinel(
            alloc,
            "{f}",
            .{trigger},
            0,
        );

        const accel: ?[:0]const u8 = accel: {
            var buf: [64]u8 = undefined;
            const a = (key.accelFromTrigger(&buf, trigger) catch break :accel null) orelse
                break :accel null;
            break :accel alloc.dupeZ(u8, a) catch break :accel null;
        };

        priv.data = .{ .keybind = .{
            .action_name = try std.fmt.allocPrintSentinel(alloc, "{t}", .{action}, 0),
            .trigger = trigger_text,
            .accel = accel,
        } };

        return self;
    }

    pub fn newCreate(
        config: *Config,
        query: []const u8,
        cwd: ?[]const u8,
    ) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{ .config = config });
        errdefer self.unref();

        const priv = self.private();
        const alloc = priv.arena.allocator();
        priv.data = .{ .create = .{
            .query = try alloc.dupeZ(u8, query),
            .subtitle = if (cwd) |v| abbreviateHome(alloc, v) else null,
        } };

        return self;
    }

    /// Create a new jump command that focuses a specific surface.
    pub fn newJump(config: *Config, surface: *Surface, plain: bool) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .config = config,
        });

        const priv = self.private();
        priv.data = .{
            .jump = .{
                .sort_key = surface.getFocusSeq(),
                .plain = plain,
            },
        };
        priv.data.jump.surface.set(surface);

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        // NOTE: we do not watch for changes to the config here as the command
        // palette will destroy and recreate this object if/when the config
        // changes.

        const priv = self.private();
        priv.arena = .init(Application.default().allocator());
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config) |config| {
            config.unref();
            priv.config = null;
        }

        switch (priv.data) {
            .regular, .create, .keybind => {},
            .jump => |*j| {
                j.surface.deinit();
            },
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.arena.deinit();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------

    fn propGetActionKey(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            // The trigger text, so that searching `ctrl+shift+p` finds the row
            // bound to it and not only the row whose action is named that.
            .keybind => |*k| return k.trigger,
            .jump, .create => return null,
        };

        if (regular.action_key) |action_key| return action_key;

        regular.action_key = std.fmt.allocPrintSentinel(
            priv.arena.allocator(),
            "{f}",
            .{regular.command.action},
            0,
        ) catch null;

        return regular.action_key;
    }

    fn propGetAction(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        const regular = switch (priv.data) {
            .regular => |*r| r,
            .keybind => |*k| return k.accel,
            .jump, .create => return null,
        };

        if (regular.action) |action| return action;

        const cfg = if (priv.config) |config| config.get() else return null;
        const keybinds = cfg.keybind.set;

        const alloc = priv.arena.allocator();

        regular.action = action: {
            var buf: [64]u8 = undefined;
            const trigger = keybinds.getTrigger(regular.command.action) orelse break :action null;
            const accel = (key.accelFromTrigger(&buf, trigger) catch break :action null) orelse break :action null;
            break :action alloc.dupeZ(u8, accel) catch return null;
        };

        return regular.action;
    }

    /// Compute and cache the project/name split for a jump entry.
    fn parseJumpTitle(self: *Self, j: *Private.JumpData) void {
        if (j.parsed) return;
        j.parsed = true;

        const priv = self.private();
        const alloc = priv.arena.allocator();

        const surface = j.surface.get() orelse return;
        defer surface.unref();

        // Only a manually set *tab* title participates in the project
        // convention. Fall back to the surface's effective title otherwise.
        const tab_ = ext.getAncestor(Tab, surface.as(gtk.Widget));
        if (tab_) |tab| {
            if (tab.getProject()) |p| j.project = alloc.dupeZ(u8, p) catch null;
        }
        const override = if (tab_) |tab| tab.getTitleOverride() else null;

        const effective_title = surface.getEffectiveTitle() orelse "Untitled";

        // In the plain palette these entries sit amongst the configured
        // commands, so they keep the prefix that tells them apart, and the
        // project convention does not apply.
        if (j.plain) {
            j.project = null;
            j.title = std.fmt.allocPrintSentinel(
                alloc,
                "Focus: {s}",
                .{effective_title},
                0,
            ) catch null;
            return;
        }

        j.title = alloc.dupeZ(u8, override orelse effective_title) catch null;
    }

    fn propGetTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => |*r| return r.command.title,
            .keybind => |*k| return k.action_name,
            .create => |*c| {
                if (c.title) |t| return t;

                // Show what will actually be made, not what was typed. The
                // label used to echo the raw query so the row kept passing a
                // plain substring filter; the filter now passes create rows
                // unconditionally, so the label is free to be useful.
                const project, const name = Window.parseQuery(c.query);
                const alloc = priv.arena.allocator();
                c.title = title: {
                    if (project) |p| {
                        if (name.len == 0) break :title std.fmt.allocPrintSentinel(
                            alloc,
                            "Create terminal in \"{s}\"",
                            .{p},
                            0,
                        ) catch null;
                        break :title std.fmt.allocPrintSentinel(
                            alloc,
                            "Create terminal \"{s}\" in \"{s}\"",
                            .{ name, p },
                            0,
                        ) catch null;
                    }
                    break :title std.fmt.allocPrintSentinel(
                        alloc,
                        "Create terminal \"{s}\"",
                        .{name},
                        0,
                    ) catch null;
                };
                return c.title;
            },
            .jump => |*j| {
                // Deliberately no "Focus: " prefix. The title is what the
                // search filter matches against, so a constant prefix on every
                // terminal is dead weight that also makes "foc" match all of
                // them. Jump entries are distinguished visually instead.
                self.parseJumpTitle(j);
                return j.title;
            },
        }
    }

    fn propGetProject(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular, .create, .keybind => return null,
            .jump => |*j| {
                self.parseJumpTitle(j);
                return j.project;
            },
        }
    }

    fn propGetProjectCss(self: *Self) ?[:0]const u8 {
        const project = self.propGetProject() orelse return null;
        return project_color.cssClass(project);
    }

    fn propGetHasProject(self: *Self) bool {
        return self.propGetProject() != null;
    }

    /// The second line of a row: the keybind action for a regular command, or
    /// the working directory for a terminal.
    fn propGetSubtitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => return self.propGetActionKey(),
            .keybind => |*k| return k.trigger,
            .create => |*c| return c.subtitle,
            .jump => |*j| {
                if (j.subtitle) |v| return v;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const pwd = surface.getPwd() orelse return null;
                j.subtitle = abbreviateHome(priv.arena.allocator(), pwd);
                return j.subtitle;
            },
        }
    }

    fn propGetDescription(self: *Self) ?[:0]const u8 {
        const priv = self.private();

        switch (priv.data) {
            .regular => |*r| return r.command.description,
            .create, .keybind => return null,
            .jump => |*j| {
                if (j.description) |desc| return desc;

                const surface = j.surface.get() orelse return null;
                defer surface.unref();

                const alloc = priv.arena.allocator();
                const title = surface.getEffectiveTitle() orelse "Untitled";
                const pwd = surface.getPwd();

                if (pwd) |p| {
                    if (std.mem.indexOf(u8, title, p) == null) {
                        j.description = alloc.dupeZ(u8, p) catch null;
                    }
                }

                return j.description;
            },
        }
    }

    //---------------------------------------------------------------

    /// Return a copy of the action. Callers must ensure that they do not use
    /// the action beyond the lifetime of this object because it has internally
    /// allocated data that will be freed when this object is.
    pub fn getAction(self: *Self) ?input.Binding.Action {
        const priv = self.private();
        return switch (priv.data) {
            .regular => |*r| r.command.action,
            .jump, .create, .keybind => null,
        };
    }

    /// Check if this is a jump command.
    pub fn isJump(self: *Self) bool {
        const priv = self.private();
        return priv.data == .jump;
    }

    /// Check if this is the synthetic "create a terminal" row.
    pub fn isCreate(self: *Self) bool {
        const priv = self.private();
        return priv.data == .create;
    }

    /// Drop the cached title/project so they are recomputed on next read.
    ///
    /// The old strings stay in the arena until this command dies. That is
    /// fine: commands live for one showing of the palette, and a rename is
    /// rare enough that the waste is a few dozen bytes.
    pub fn invalidateTitle(self: *Self) void {
        const priv = self.private();
        switch (priv.data) {
            .regular, .create, .keybind => return,
            .jump => |*j| {
                j.title = null;
                j.project = null;
                j.parsed = false;
            },
        }

        self.as(gobject.Object).notifyByPspec(properties.title.impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.project.impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"has-project".impl.param_spec);
        // The colour is derived from the name, so it is stale too. Forgetting
        // this left a freshly assigned project uncoloured until the palette was
        // closed and reopened, which is exactly when a user checks their work.
        self.as(gobject.Object).notifyByPspec(properties.@"project-css".impl.param_spec);
    }

    /// The text the user had typed when this create row was built.
    pub fn getCreateQuery(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        return switch (priv.data) {
            .regular, .jump => null,
            .create => |*c| c.query,
        };
    }

    /// Get the jump surface. Returns a strong reference that the caller
    /// must unref when done, or null if the surface has been destroyed.
    pub fn getJumpSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return switch (priv.data) {
            .regular, .create, .keybind => null,
            .jump => |*j| j.surface.get(),
        };
    }

    //---------------------------------------------------------------

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
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.action_key.impl,
                properties.action.impl,
                properties.title.impl,
                properties.description.impl,
                properties.project.impl,
                properties.@"project-css".impl,
                properties.@"has-project".impl,
                properties.subtitle.impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};
