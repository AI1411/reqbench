const std = @import("std");

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    _ = try stdout.write("reqbench v0.1.0\n");
}

test {
    // 全モジュールのテストを引き込む
    _ = @import("config/scenario.zig");
    _ = @import("utils/ring_buffer.zig");
    _ = @import("utils/time.zig");
    _ = @import("metrics/histogram.zig");
    _ = @import("metrics/collector.zig");
    _ = @import("http/request.zig");
    _ = @import("http/response.zig");
    _ = @import("engine/scheduler.zig");
    _ = @import("config/env.zig");
}
