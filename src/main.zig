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

    var cols: u32 = undefined; // editor rows
    var rows: u32 = undefined; // editor columns

    var cy: u32 = 0; // cursor row
    var cx: u32 = 0; // cursor col

    var rowoff: u32 = 0; // window first row
    var coloff: u32 = 0; // window first col

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
                Escape.MOVE_CURSOR => try std.fmt.format(writer, "\x1b[{d};{d}H", .{ cy - rowoff + 1, get_cx() - coloff + 1 }),
            }
        }
    };

    fn get_cx() u32 {
        return @min(cx, data.items[cy].items.len);
    }

    fn init() !void {
        var wsz: posix.system.winsize = undefined;
        const err = posix.errno(posix.system.ioctl(posix.STDIN_FILENO, posix.T.IOCGWINSZ, &wsz));

        if (err != .SUCCESS) {
            return error.IoctlError;
        }

        cols = wsz.ws_col;
        rows = wsz.ws_row;

        try data.append(std.ArrayList(u8).init(alloc.allocator()));
    }

    fn render() !void {
        var buf = std.ArrayList(u8).init(alloc.allocator());
        defer buf.deinit();

        const writer = buf.writer();

        try Escape.HIDE_CURSOR.write(writer);
        try Escape.CURSOR_TL.write(writer);

        var row: usize = 0;
        while (row < rows - 1) : (row += 1) {
            if (row + rowoff < data.items.len) {
                var len = data.items[row + rowoff].items.len - coloff;
                if (len > cols) len = cols;

                try writer.writeAll(data.items[row + rowoff].items[coloff .. coloff + len]);
            } else {
                try writer.writeAll("~");
            }
            try Escape.CLEAR_LINE.write(writer);
            try writer.writeAll("\r\n");
        }
        try writer.writeAll(cmd.items);

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
        scroll();
    }

    fn handle_normal(ch: u8) !void {
        switch (ch) {
            ':' => {
                mode = Mode.Command;
            },
            'i' => {
                mode = Mode.Insert;
                cx = get_cx();
            },
            'a' => {
                mode = Mode.Insert;
                cx += 1;
                cx = get_cx();
            },
            'I' => {
                mode = Mode.Insert;
                cx = 0;
                while (cx < data.items[cy].items.len and is_whitespace(data.items[cy].items[cx])) {
                    cx += 1;
                }
            },
            'A' => {
                mode = Mode.Insert;
                cx = @intCast(data.items[cy].items.len);
            },
            'h' => {
                if (cx > 0) cx -= 1;
            },
            'j' => {
                if (cy < data.items.len - 1) cy += 1;
            },
            'k' => {
                if (cy > 0) cy -= 1;
            },
            'l' => {
                if (cx < data.items[cy].items.len) cx += 1;
            },
            'w' => {
                var seen_ws = false;
                while (cy < data.items.len) : (cy += 1) {
                    while (cx < data.items[cy].items.len) : (cx += 1) {
                        if (is_whitespace(data.items[cy].items[cx])) {
                            seen_ws = true;
                        } else if (seen_ws) {
                            return;
                        }
                    }
                    cx = 0;
                    seen_ws = true;
                }
                cy -= 1;
                cx = @intCast(data.items[cy].items.len);
            },
            'o' => {
                try data.insert(cy + 1, std.ArrayList(u8).init(alloc.allocator()));
                cy += 1;
                cx = 0;
                mode = Mode.Insert;
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
                try data.insert(cy + 1, std.ArrayList(u8).init(alloc.allocator()));
                const writer = data.items[cy + 1].writer();
                _ = try writer.write(data.items[cy].items[cx..]);
                try data.items[cy].resize(cx);
                cy += 1;
                cx = 0;
            },
            '\x7f' => {
                if (cx == 0) {} else {
                    _ = data.items[cy].orderedRemove(cx - 1);
                    cx -= 1;
                }
            },
            else => {
                try data.items[cy].insert(cx, ch);
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

    fn scroll() void {
        if (get_cx() < coloff) {
            coloff = cx;
        }
        if (get_cx() >= cols + coloff) {
            coloff = get_cx() - cols + 1;
        }

        if (cy < rowoff) {
            rowoff = cy;
        }
        if (cy >= rows + rowoff) {
            rowoff = cy - rows + 1;
        }
    }

    fn is_whitespace(ch: u8) bool {
        return (ch == ' ' or
            ch == '\n' or
            ch == '\t' or
            ch == '\r');
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
