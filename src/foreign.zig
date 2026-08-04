//! Foreign-import argument types and the limits every VIG tool enforces.
//!
//! Foreign calls are deliberately restricted to a small, predictable ABI
//! surface: enough for simple Windows APIs without exposing arbitrary host
//! pointers or callbacks to VIG programs. These limits are part of the container
//! format, so the assembler and the VM have to agree on them exactly.

const std = @import("std");

pub const max_imports = 16;
pub const max_args = 4;
pub const max_name_len = 255;

/// Largest import table a valid container can hold: every import at the maximum
/// argument count with maximum-length library and symbol names.
pub const max_table_size = max_imports * (3 + max_args + 2 * max_name_len);

/// How one foreign argument is marshalled. `ptr` and `cstr` are offsets into the
/// loaded program image, never native addresses.
pub const ArgType = enum(u8) {
    i32 = 0,
    u32 = 1,
    ptr = 2,
    cstr = 3,

    pub fn fromByte(byte: u8) error{InvalidForeignType}!ArgType {
        return std.enums.fromInt(ArgType, byte) orelse error.InvalidForeignType;
    }

    /// Look up the type an assembler `extern` declaration names. The spelling in
    /// source is the tag name, so the two cannot drift apart.
    pub fn fromName(text: []const u8) ?ArgType {
        return std.meta.stringToEnum(ArgType, text);
    }

    pub fn name(self: ArgType) []const u8 {
        return @tagName(self);
    }
};

/// One `extern` declaration, as recorded in a container's import table. The
/// name slices point into whatever buffer the declaration was read from.
pub const Import = struct {
    library: []const u8,
    symbol: []const u8,
    arg_types: [max_args]ArgType = @splat(.u32),
    arg_count: u8 = 0,

    pub fn argTypes(self: *const Import) []const ArgType {
        return self.arg_types[0..self.arg_count];
    }

    /// Encoded length: the three length bytes, one byte per argument type, then
    /// the two unterminated names.
    pub fn encodedSize(self: Import) usize {
        return 3 + @as(usize, self.arg_count) + self.library.len + self.symbol.len;
    }

    pub fn addArg(self: *Import, arg_type: ArgType) error{TooManyForeignArguments}!void {
        if (self.arg_count >= max_args) return error.TooManyForeignArguments;
        self.arg_types[self.arg_count] = arg_type;
        self.arg_count += 1;
    }
};

test "argument types round-trip through their byte and their name" {
    for ([_]ArgType{ .i32, .u32, .ptr, .cstr }) |arg_type| {
        try std.testing.expectEqual(arg_type, try ArgType.fromByte(@intFromEnum(arg_type)));
        try std.testing.expectEqual(arg_type, ArgType.fromName(arg_type.name()).?);
    }
    try std.testing.expectError(error.InvalidForeignType, ArgType.fromByte(4));
    try std.testing.expectEqual(@as(?ArgType, null), ArgType.fromName("f32"));
}

test "imports report their encoded size and reject a fifth argument" {
    var import: Import = .{ .library = "user32.dll", .symbol = "MessageBoxA" };
    for ([_]ArgType{ .ptr, .cstr, .cstr, .u32 }) |arg_type| try import.addArg(arg_type);
    try std.testing.expectError(error.TooManyForeignArguments, import.addArg(.i32));

    try std.testing.expectEqual(@as(usize, 4), import.argTypes().len);
    try std.testing.expectEqual(@as(usize, 3 + 4 + 10 + 11), import.encodedSize());
}
