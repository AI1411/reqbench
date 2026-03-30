// src/tui/layout.zig
const std = @import("std");

pub const TermSize = struct { rows: u16, cols: u16 };

pub fn getTermSize() TermSize {
    var ws: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (rc == 0 and ws.ws_row > 0) return .{ .rows = ws.ws_row, .cols = ws.ws_col };
    return .{ .rows = 24, .cols = 80 }; // フォールバック
}

pub const Layout = struct {
    header_rows: u16 = 4,
    table_rows: u16,
    hist_rows: u16 = 10,
    graph_rows: u16 = 8,
    footer_rows: u16 = 2,
    cols: u16,

    pub fn from(ts: TermSize, endpoint_count: u16) Layout {
        const table = @min(endpoint_count + 3, ts.rows / 3);
        return .{ .table_rows = table, .cols = ts.cols };
    }
};

test "layout from terminal size" {
    const ts = TermSize{ .rows = 24, .cols = 80 };
    const layout = Layout.from(ts, 3);
    try std.testing.expectEqual(@as(u16, 80), layout.cols);
    try std.testing.expect(layout.table_rows > 0);
}
