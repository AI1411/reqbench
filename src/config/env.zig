const std = @import("std");

pub const ExpandError = error{ EnvVarNotFound, OutOfMemory };

/// allocator はArenaを想定。
pub fn expand(input: []const u8, allocator: std.mem.Allocator) ExpandError![]u8 {
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '$' and input[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, input, i + 2, '}') orelse {
                try out.appendSlice(allocator, input[i .. i + 2]);
                i += 2;
                continue;
            };
            const var_name = input[i + 2 .. end];
            const val = std.posix.getenv(var_name) orelse return error.EnvVarNotFound;
            try out.appendSlice(allocator, val);
            i = end + 1;
        } else {
            var j = i + 1;
            while (j < input.len and !(input[j] == '$' and j + 1 < input.len and input[j + 1] == '{')) : (j += 1) {}
            try out.appendSlice(allocator, input[i..j]);
            i = j;
        }
    }
    return out.toOwnedSlice(allocator);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

test "expand: no variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expand("http://localhost:8080", arena.allocator());
    try std.testing.expectEqualStrings("http://localhost:8080", result);
}

test "expand: replaces known env var" {
    _ = setenv("TEST_TOKEN", "abc123", 1);
    defer _ = setenv("TEST_TOKEN", "", 1);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try expand("Bearer ${TEST_TOKEN}", arena.allocator());
    try std.testing.expectEqualStrings("Bearer abc123", result);
}

test "expand: missing var returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EnvVarNotFound, expand("${REQBENCH_MISSING_VAR_XYZ}", arena.allocator()));
}
