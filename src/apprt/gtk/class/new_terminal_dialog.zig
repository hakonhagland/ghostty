const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const ext = @import("../ext.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_new_terminal_dialog);

/// Ask for a name and a project before creating a terminal.
///
/// The switcher can already create one from the query alone, and `Ctrl+Enter`
/// creates one with no prompt at all. This exists for the case those two do not
/// serve: naming a project that does not exist yet, without having to know the
/// `@project name` shorthand. Both fields are prefilled from whatever the query
/// did say, so accepting the defaults is a single Enter.
pub const NewTerminalDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.AlertDialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyNewTerminalDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        /// Create a terminal with the given name and project. Either may be
        /// empty, meaning "none".
        pub const create = struct {
            pub const name = "create";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{ [*:0]const u8, [*:0]const u8 },
                void,
            );
        };
    };

    const Private = struct {
        /// Prefill values, owned by this object until it is finalized.
        initial_name: ?[:0]const u8 = null,
        initial_project: ?[:0]const u8 = null,

        // Template bindings
        name_entry: *adw.EntryRow,
        project_entry: *adw.EntryRow,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn new(name: []const u8, project: []const u8) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        if (name.len > 0) priv.initial_name = glib.ext.dupeZ(u8, name);
        if (project.len > 0) priv.initial_project = glib.ext.dupeZ(u8, project);
        return self;
    }

    pub fn present(self: *Self, parent_: *gtk.Widget) void {
        const parent: *gtk.Widget = if (ext.getAncestor(
            adw.ApplicationWindow,
            parent_,
        )) |window|
            window.as(gtk.Widget)
        else if (ext.getAncestor(
            adw.Window,
            parent_,
        )) |window|
            window.as(gtk.Widget)
        else
            parent_;

        const priv = self.private();
        if (priv.initial_name) |v| {
            priv.name_entry.as(gtk.Editable).setText(v);
        }
        if (priv.initial_project) |v| {
            priv.project_entry.as(gtk.Editable).setText(v);
        }

        self.as(adw.AlertDialog).choose(
            parent,
            null,
            alertDialogReady,
            self,
        );
    }

    fn alertDialogReady(
        _: ?*gobject.Object,
        result: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));
        const response = self.as(adw.AlertDialog).chooseFinish(result);
        if (std.mem.orderZ(u8, "ok", response) != .eq) return;

        const priv = self.private();
        const name = std.mem.span(priv.name_entry.as(gtk.Editable).getText());
        const project = std.mem.span(priv.project_entry.as(gtk.Editable).getText());

        signals.create.impl.emit(
            self,
            null,
            .{ name.ptr, project.ptr },
            null,
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
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
        if (priv.initial_name) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.initial_name = null;
        }
        if (priv.initial_project) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.initial_project = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "new-terminal-dialog",
                }),
            );

            class.bindTemplateChildPrivate("name_entry", .{});
            class.bindTemplateChildPrivate("project_entry", .{});

            signals.create.impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
