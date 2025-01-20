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
        while (row < rows) : (row += 1) {
            if (row + ro < data.items.len) {
                var len = data.items[row + ro].items.len;
                if (len > cols) len = cols;

                try writer.writeAll(data.items[row + ro].items[0..len]);
            } else {
                try writer.writeAll("~");
            }
            try Escape.CLEAR_LINE.write(writer);
            try writer.writeAll("\r\n");
        }

        try Escape.MOVE_CURSOR.write(writer);
        try Escape.SHOW_CURSOR.write(writer);
        try std.io.getStdOut().writeAll(buf.items);
    }

    fn handle_input() !void {
        var buf: [1]u8 = undefined;
        _ = try std.io.getStdIn().read(buf[0..]);

        if (buf[0] == 'q') {
            done = true;
        }
    }

    fn clean() !void {
        data.deinit();
        _ = alloc.detectLeaks();
    }
};
