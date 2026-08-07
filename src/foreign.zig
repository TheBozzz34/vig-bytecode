//! The argument types for a foreign import, and the limits that each VIG tool
//! applies.
//!
//! A foreign call has a small and simple application binary interface (ABI).
//! The ABI is sufficient for a simple Windows API function. It gives a VIG
//! program no host pointer and no callback function. These limits are part of
//! the container format. Therefore the assembler and the VM must apply exactly
//! the same limits.

const std = @import("std");

pub const max_imports = 16;
pub const max_args = 4;
/// The portable VIG64 foreign ABI has room for normal C library calls such as
/// `CreateFile` without changing a host calling convention.
pub const vig64_max_args = 16;
pub const max_name_len = 255;

/// The largest import table that a correct container can hold. Each import has
/// the maximum number of arguments. The library name and the symbol name are
/// both at the maximum length.
pub const max_table_size = max_imports * (3 + max_args + 2 * max_name_len);

/// How the VM prepares one foreign argument. A `ptr` value and a `cstr` value
/// are offsets into the program image in VM memory. They are not host addresses.
pub const ArgType = enum(u8) {
    i32 = 0,
    u32 = 1,
    ptr = 2,
    cstr = 3,

    pub fn fromByte(byte: u8) error{InvalidForeignType}!ArgType {
        return std.enums.fromInt(ArgType, byte) orelse error.InvalidForeignType;
    }

    /// Find the type that an assembler `extern` declaration names. The source
    /// text of the declaration is the name of the tag. Therefore the two cannot
    /// become different.
    pub fn fromName(text: []const u8) ?ArgType {
        return std.meta.stringToEnum(ArgType, text);
    }

    pub fn name(self: ArgType) []const u8 {
        return @tagName(self);
    }
};

/// One `extern` declaration, in the form that the import table of a container
/// holds. The name slices point into the buffer that supplied the declaration.
pub const Import = struct {
    library: []const u8,
    symbol: []const u8,
    arg_types: [max_args]ArgType = @splat(.u32),
    arg_count: u8 = 0,

    pub fn argTypes(self: *const Import) []const ArgType {
        return self.arg_types[0..self.arg_count];
    }

    /// The encoded length: the three length bytes, then one byte for each
    /// argument type, then the two names. The names have no terminator byte.
    pub fn encodedSize(self: Import) usize {
        return 3 + @as(usize, self.arg_count) + self.library.len + self.symbol.len;
    }

    pub fn addArg(self: *Import, arg_type: ArgType) error{TooManyForeignArguments}!void {
        if (self.arg_count >= max_args) return error.TooManyForeignArguments;
        self.arg_types[self.arg_count] = arg_type;
        self.arg_count += 1;
    }
};

/// The type of one VIG64 foreign argument. A guest pointer is an address in VM
/// memory. A host pointer is opaque: guest code may pass it back to a foreign
/// call but cannot use it as a memory address.
pub const Vig64Type = enum(u8) {
    i32 = 0,
    u32 = 1,
    i64 = 2,
    u64 = 3,
    guest_ptr = 4,
    host_ptr = 5,
    f32 = 6,
    f64 = 7,

    pub fn fromByte(byte: u8) error{InvalidForeignType}!Vig64Type {
        return std.enums.fromInt(Vig64Type, byte) orelse error.InvalidForeignType;
    }

    pub fn fromName(text: []const u8) ?Vig64Type {
        return std.meta.stringToEnum(Vig64Type, text);
    }
};

/// The return type of a VIG64 foreign call. `void` is distinct from an integer
/// zero, so the caller can keep its operand stack shape correct.
pub const Vig64ResultType = enum(u8) {
    void = 0,
    i32 = 1,
    u32 = 2,
    i64 = 3,
    u64 = 4,
    guest_ptr = 5,
    host_ptr = 6,
    f32 = 7,
    f64 = 8,

    pub fn fromByte(byte: u8) error{InvalidForeignType}!Vig64ResultType {
        return std.enums.fromInt(Vig64ResultType, byte) orelse error.InvalidForeignType;
    }

    pub fn fromName(text: []const u8) ?Vig64ResultType {
        return std.meta.stringToEnum(Vig64ResultType, text);
    }
};

/// One VIG64 import declaration. This is separate from `Import` because its
/// encoded table is not compatible with the VIG32 table.
pub const Vig64Import = struct {
    library: []const u8,
    symbol: []const u8,
    result: Vig64ResultType = .u64,
    arg_types: [vig64_max_args]Vig64Type = @splat(.u64),
    arg_count: u8 = 0,

    pub fn argTypes(self: *const Vig64Import) []const Vig64Type {
        return self.arg_types[0..self.arg_count];
    }

    /// The VIG64 table record stores the two name lengths, the argument count,
    /// the result type, the argument types, and the two names.
    pub fn encodedSize(self: Vig64Import) usize {
        return 4 + @as(usize, self.arg_count) + self.library.len + self.symbol.len;
    }

    pub fn addArg(self: *Vig64Import, arg_type: Vig64Type) error{TooManyForeignArguments}!void {
        if (self.arg_count >= vig64_max_args) return error.TooManyForeignArguments;
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

test "VIG64 imports hold a typed result and sixteen arguments" {
    var import: Vig64Import = .{ .library = "kernel32.dll", .symbol = "CreateFileA", .result = .host_ptr };
    for (0..vig64_max_args) |_| try import.addArg(.u64);
    try std.testing.expectError(error.TooManyForeignArguments, import.addArg(.u64));
    try std.testing.expectEqual(@as(usize, vig64_max_args), import.argTypes().len);
    try std.testing.expectEqual(@as(usize, 4 + vig64_max_args + 12 + 11), import.encodedSize());
    try std.testing.expectEqual(Vig64Type.f64, try Vig64Type.fromByte(7));
    try std.testing.expectEqual(Vig64ResultType.void, try Vig64ResultType.fromByte(0));
}
