const std = @import("std");
const posix = @import("std").posix;

pub fn main() !void {
    try Termio.uncook();
    defer Termio.cook() catch {};

    try Editor.init();
    defer Editor.clean() catch {};

    while (!Editor.done) {
        try Editor.render();
        try Editor.handle_input();
    }
}

const Termio = struct {
    var original: posix.termios = undefined;

    fn uncook() !void {
        original = try posix.tcgetattr(posix.STDIN_FILENO);

        var uncooked = original;

        const iflags = [_][]const u8{ "BRKINT", "ICRNL", "INPCK", "ISTRIP", "IXON" };
        inline for (iflags) |flag| {
            @field(uncooked.iflag, flag) = false;
        }

        const lflags = [_][]const u8{ "ECHO", "ICANON", "IEXTEN", "ISIG" };
        inline for (lflags) |flag| {
            @field(uncooked.lflag, flag) = false;
        }

        uncooked.oflag.OPOST = false;
        uncooked.cflag.CSIZE = .CS8;

        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, uncooked);
    }

    fn cook() !void {
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original);
    }
};

const Editor = struct {
    var done: bool = false;

    var cols: u16 = undefined;
    var rows: u16 = undefined;
    var cy: u16 = 0; // cursor row
    var cx: u16 = 0; // cursor col
    var ro: u16 = 0; // window first row
    var co: u16 = 0; // window first col

    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    var data = std.ArrayList(std.ArrayList(u8)).init(alloc.allocator());
    var cmd = std.ArrayList(u8).init(alloc.allocator());

    const Mode = enum { Normal, Insert, Command };

    var mode: Mode = Mode.Normal;

    const Escape = enum {
        CLEAR_LINE,
        HIDE_CURSOR,
        SHOW_CURSOR,
        CLEAR_SCREEN,
        CURSOR_TL,
        MOVE_CURSOR,

        fn write(self: Escape, writer: anytype) !void {
            switch (self) {
                Escape.CLEAR_LINE => try writer.writeAll("\x1b[K"),
                Escape.HIDE_CURSOR => try writer.writeAll("\x1b[?25l"),
                Escape.SHOW_CURSOR => try writer.writeAll("\x1b[?25h"),
                Escape.CLEAR_SCREEN => try writer.writeAll("\x1b[2J"),
                Escape.CURSOR_TL => try writer.writeAll("\x1b[H"),
                Escape.MOVE_CURSOR => try std.fmt.format(writer, "\x1b[{d};{d}H", .{ cy + 1, cx + 1 }),
            }
        }
    };

    fn init() !void {
        var wsz: posix.system.winsize = undefined;
        const err = posix.errno(posix.system.ioctl(posix.STDIN_FILENO, posix.T.IOCGWINSZ, &wsz));

        if (err != .SUCCESS) {
            return error.IoctlError;
        }

        cols = wsz.ws_col;
        rows = wsz.ws_row;
    }

    fn render() !void {
        var buf = std.ArrayList(u8).init(alloc.allocator());
        defer buf.deinit();

        const writer = buf.writer();

        try Escape.HIDE_CURSOR.write(writer);
        try Escape.CURSOR_TL.write(writer);

        var row: usize = 0;
        while (row < rows - 1) : (row += 1) {
            if (row + ro < data.items.len) {
                var len = data.items[row + ro].items.len - co;
                if (len > cols) len = cols;

                try writer.writeAll(data.items[row + ro].items[co .. co + len]);
            } else {
                try writer.writeAll("~");
            }
            try Escape.CLEAR_LINE.write(writer);
            try writer.writeAll("\r\n");
        }

        try writer.writeAll(cmd.items[0..]);

        try Escape.MOVE_CURSOR.write(writer);
        try Escape.SHOW_CURSOR.write(writer);
        try std.io.getStdOut().writeAll(buf.items);
    }

    fn handle_input() !void {
        var buf: [1]u8 = undefined;
        _ = try std.io.getStdIn().read(buf[0..]);
        const ch = buf[0];

        switch (mode) {
            Mode.Normal => try handle_normal(ch),
            Mode.Insert => try handle_insert(ch),
            Mode.Command => try handle_command(ch),
        }

        if (cy + ro < data.items.len) {
            const width: u16 = @intCast(data.items[cy + ro].items.len);
            if (cx + co > width) {
                cx = @min(cols - 1, width);
                co = width - cx;
            }
        } else {
            if (cy + ro != 0) {
                cy -= 1;
            } else {
                cx = 0;
                co = 0;
            }
        }

        if (cx == cols) {
            cx -= 1;
            co += 1;
        }
        if (cy == rows) {
            cy -= 1;
            ro += 1;
        }
    }

    fn handle_normal(ch: u8) !void {
        switch (ch) {
            ':' => {
                mode = Mode.Command;
            },
            'i' => {
                mode = Mode.Insert;
                if (data.items.len == 0) {
                    try data.append(std.ArrayList(u8).init(alloc.allocator()));
                }
            },
            'h' => {
                if (cx > 0) {
                    cx -= 1;
                } else if (co > 0) {
                    co -= 1;
                }
            },
            'j' => {
                cy += 1;
            },
            'k' => {
                if (cy > 0) {
                    cy -= 1;
                } else if (ro > 0) {
                    ro -= 1;
                }
            },
            'l' => {
                cx += 1;
            },
            else => {},
        }
    }

    fn handle_insert(ch: u8) !void {
        switch (ch) {
            '\x1b' => {
                mode = Mode.Normal;
            },
            '\r' => {
                try data.insert(ro + cy + 1, std.ArrayList(u8).init(alloc.allocator()));
                cy += 1;
            },
            '\x7f' => {
                if (cx + co == 0) {} else {
                    _ = data.items[cy + ro].orderedRemove(cx + co - 1);
                }
            },
            else => {
                try data.items[ro + cy].insert(co + cx, ch);
                cx += 1;
            },
        }
    }

    fn handle_command(ch: u8) !void {
        if (ch == '\r') {
            // todo exe cmd
            done = true;
        } else if (ch == '\x1b') {
            mode = Mode.Normal;
        } else {
            try cmd.append(ch);
        }
    }

    fn clean() !void {
        for (data.items) |row| {
            row.deinit();
        }

        data.deinit();
        cmd.deinit();

        _ = alloc.detectLeaks();
    }
};
