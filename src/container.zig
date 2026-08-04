//! The VIG container format: the on-disk wrapper around a program image.
//!
//! Format version 2 records the shape of the program explicitly instead of
//! leaving it implicit in the file length:
//!
//! ```text
//! offset size field
//!      0    4 magic "VIGF"
//!      4    1 format version
//!      5    1 flags
//!      6    1 import count
//!      7    1 reserved, must be zero
//!      8    4 code length      (little-endian u32)
//!     12    4 static-data length
//!     16    4 entry point, a code offset
//!     20    4 import-table length in bytes
//!     24      import table, `import count` entries
//!            code
//!            static data
//! ```
//!
//! Splitting code from static data is what makes instruction-boundary
//! verification possible: strings live outside the executable region, so a
//! verifier can walk the code region without tripping over text, and jumps can
//! be required to land on an instruction. The import-table length lets a reader
//! find the code without decoding imports, and the version and flags fields let
//! a reader reject a container it does not fully understand instead of guessing.
//!
//! Version 1 containers (a six-byte prefix followed by an import table and a
//! mixed code-and-data blob) and bare headerless code are still readable, so
//! programs assembled before this format existed keep running. They carry no
//! code/data split, so they cannot be verified.

const std = @import("std");
const foreign = @import("foreign.zig");

pub const magic = "VIGF";

/// Format version this package writes.
pub const version: u8 = 2;
/// Earlier format: magic, version, import count, then imports and one blob.
pub const legacy_version: u8 = 1;

pub const header_size = 24;
pub const legacy_header_size = 6;

const offset_version = 4;
const offset_flags = 5;
const offset_import_count = 6;
const offset_reserved = 7;
const offset_code_len = 8;
const offset_data_len = 12;
const offset_entry_point = 16;
const offset_import_table_len = 20;

pub const Error = error{
    InvalidContainerHeader,
    UnsupportedContainerVersion,
    UnsupportedContainerFlags,
    ContainerSizeMismatch,
    EntryPointOutOfRange,
    TooManyForeignImports,
    TooManyForeignArguments,
    ForeignNameTooLong,
    InvalidForeignType,
    BufferTooSmall,
};

/// Container-wide flags. Every bit is reserved in format version 2, and a reader
/// rejects any that are set: a future flag has to be understood to be honoured,
/// so an older VM must refuse the container rather than ignore the bit.
pub const Flags = packed struct(u8) {
    reserved: u8 = 0,

    pub fn toByte(self: Flags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) Error!Flags {
        const flags: Flags = @bitCast(byte);
        if (flags.reserved != 0) return error.UnsupportedContainerFlags;
        return flags;
    }
};

pub const Header = struct {
    format_version: u8 = version,
    flags: Flags = .{},
    import_count: u8 = 0,
    code_len: u32 = 0,
    data_len: u32 = 0,
    entry_point: u32 = 0,
    import_table_len: u32 = 0,
};

/// How a file described its contents.
pub const Kind = enum {
    /// No magic: the whole file is code, as the very first VIG programs were.
    raw,
    /// Format version 1: an import table followed by code and data in one blob.
    legacy,
    /// Format version 2, the layout documented at the top of this file.
    current,

    /// Whether the container distinguishes code from static data, which a
    /// verifier needs in order to know where instructions stop.
    pub fn separatesData(self: Kind) bool {
        return self == .current;
    }
};

/// A parsed container: the header plus borrowed slices into the source bytes.
pub const Image = struct {
    kind: Kind,
    header: Header,
    /// Encoded import table; walk it with `importIterator`.
    imports: []const u8,
    /// Executable instructions. Nothing outside this range is ever executed.
    code: []const u8,
    /// Static data mapped immediately after the code, so an address pushed by a
    /// program indexes `code ++ data`. Always empty for `raw` and `legacy`.
    data: []const u8,

    /// Bytes the program occupies in VM memory.
    pub fn imageLen(self: Image) usize {
        return self.code.len + self.data.len;
    }

    pub fn importIterator(self: Image) ImportIterator {
        return .{ .bytes = self.imports, .remaining = self.header.import_count };
    }
};

pub fn isContainer(bytes: []const u8) bool {
    return bytes.len >= magic.len and std.mem.eql(u8, bytes[0..magic.len], magic);
}

/// Largest valid file for a VM whose program image is at most `image_size`
/// bytes: the header, the largest possible import table, and the image.
pub fn maxFileSize(image_size: usize) usize {
    return header_size + foreign.max_table_size + image_size;
}

pub fn writeHeader(header: Header, dest: *[header_size]u8) void {
    @memcpy(dest[0..magic.len], magic);
    dest[offset_version] = header.format_version;
    dest[offset_flags] = header.flags.toByte();
    dest[offset_import_count] = header.import_count;
    dest[offset_reserved] = 0;
    std.mem.writeInt(u32, dest[offset_code_len..][0..4], header.code_len, .little);
    std.mem.writeInt(u32, dest[offset_data_len..][0..4], header.data_len, .little);
    std.mem.writeInt(u32, dest[offset_entry_point..][0..4], header.entry_point, .little);
    std.mem.writeInt(u32, dest[offset_import_table_len..][0..4], header.import_table_len, .little);
}

/// Read a format-version-2 header. Field consistency against the rest of the
/// file is checked by `parse`.
pub fn readHeader(bytes: []const u8) Error!Header {
    if (!isContainer(bytes) or bytes.len < header_size) return error.InvalidContainerHeader;
    if (bytes[offset_version] != version) return error.UnsupportedContainerVersion;
    if (bytes[offset_reserved] != 0) return error.InvalidContainerHeader;

    const import_count = bytes[offset_import_count];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;

    return .{
        .format_version = bytes[offset_version],
        .flags = try Flags.fromByte(bytes[offset_flags]),
        .import_count = import_count,
        .code_len = std.mem.readInt(u32, bytes[offset_code_len..][0..4], .little),
        .data_len = std.mem.readInt(u32, bytes[offset_data_len..][0..4], .little),
        .entry_point = std.mem.readInt(u32, bytes[offset_entry_point..][0..4], .little),
        .import_table_len = std.mem.readInt(u32, bytes[offset_import_table_len..][0..4], .little),
    };
}

/// Parse any container this package can read, current or legacy.
pub fn parse(bytes: []const u8) Error!Image {
    if (!isContainer(bytes)) {
        return .{
            .kind = .raw,
            .header = .{ .format_version = 0, .code_len = try castLen(bytes.len) },
            .imports = &.{},
            .code = bytes,
            .data = &.{},
        };
    }

    if (bytes.len > magic.len and bytes[offset_version] == legacy_version) return parseLegacy(bytes);

    const header = try readHeader(bytes);
    const declared = @as(u64, header_size) + header.import_table_len + header.code_len + header.data_len;
    if (declared != bytes.len) return error.ContainerSizeMismatch;

    // Safe now that the declared lengths are known to sum to the file size.
    const code_start = header_size + @as(usize, header.import_table_len);
    const code_end = code_start + @as(usize, header.code_len);

    const imports = bytes[header_size..code_start];
    // A table that does not decode to exactly `import_count` entries filling
    // `import_table_len` bytes means the header and the table disagree.
    if (try importTableSize(imports, header.import_count) != imports.len) {
        return error.ContainerSizeMismatch;
    }

    try checkEntryPoint(header.entry_point, header.code_len);

    return .{
        .kind = .current,
        .header = header,
        .imports = imports,
        .code = bytes[code_start..code_end],
        .data = bytes[code_end..],
    };
}

fn parseLegacy(bytes: []const u8) Error!Image {
    if (bytes.len < legacy_header_size) return error.InvalidContainerHeader;

    const import_count = bytes[5];
    if (import_count > foreign.max_imports) return error.TooManyForeignImports;

    const rest = bytes[legacy_header_size..];
    const table_len = try importTableSize(rest, import_count);

    return .{
        .kind = .legacy,
        .header = .{
            .format_version = legacy_version,
            .import_count = import_count,
            .code_len = try castLen(rest.len - table_len),
            .import_table_len = @intCast(table_len),
        },
        .imports = rest[0..table_len],
        // Version 1 mixed strings into the code blob, so everything after the
        // import table has to stay executable and addressable.
        .code = rest[table_len..],
        .data = &.{},
    };
}

fn castLen(len: usize) Error!u32 {
    return std.math.cast(u32, len) orelse error.ContainerSizeMismatch;
}

fn checkEntryPoint(entry_point: u32, code_len: usize) Error!void {
    if (code_len == 0) {
        if (entry_point != 0) return error.EntryPointOutOfRange;
        return;
    }
    if (entry_point >= code_len) return error.EntryPointOutOfRange;
}

/// Bytes the first `count` import entries occupy.
pub fn importTableSize(bytes: []const u8, count: u8) Error!usize {
    var iterator: ImportIterator = .{ .bytes = bytes, .remaining = count };
    while (try iterator.next()) |_| {}
    return iterator.offset;
}

pub const ImportIterator = struct {
    bytes: []const u8,
    offset: usize = 0,
    remaining: u8,

    pub fn next(self: *ImportIterator) Error!?foreign.Import {
        if (self.remaining == 0) return null;
        self.remaining -= 1;

        if (self.bytes.len - self.offset < 3) return error.InvalidContainerHeader;
        const library_len: usize = self.bytes[self.offset];
        const symbol_len: usize = self.bytes[self.offset + 1];
        const arg_count: usize = self.bytes[self.offset + 2];
        self.offset += 3;

        if (arg_count > foreign.max_args) return error.TooManyForeignArguments;
        if (self.bytes.len - self.offset < arg_count) return error.InvalidContainerHeader;

        var import: foreign.Import = .{ .library = "", .symbol = "" };
        for (self.bytes[self.offset..][0..arg_count]) |byte| {
            try import.addArg(try foreign.ArgType.fromByte(byte));
        }
        self.offset += arg_count;

        const names_len = library_len + symbol_len;
        if (self.bytes.len - self.offset < names_len) return error.InvalidContainerHeader;
        import.library = self.bytes[self.offset..][0..library_len];
        import.symbol = self.bytes[self.offset + library_len ..][0..symbol_len];
        self.offset += names_len;

        return import;
    }
};

/// What `write` should lay out. `code` and `data` are already-assembled regions;
/// addresses inside the program treat them as one contiguous image.
pub const Layout = struct {
    imports: []const foreign.Import = &.{},
    code: []const u8,
    data: []const u8 = &.{},
    entry_point: u32 = 0,
    flags: Flags = .{},
};

/// Exact file size `write` will produce for `layout`.
pub fn encodedSize(layout: Layout) Error!usize {
    return header_size + try importTableLen(layout.imports) + layout.code.len + layout.data.len;
}

/// Write a complete container into `dest`, returning the bytes written.
pub fn write(layout: Layout, dest: []u8) Error!usize {
    const table_len = try importTableLen(layout.imports);
    try checkEntryPoint(layout.entry_point, layout.code.len);

    const total = header_size + table_len + layout.code.len + layout.data.len;
    if (dest.len < total) return error.BufferTooSmall;

    writeHeader(.{
        .flags = layout.flags,
        .import_count = @intCast(layout.imports.len),
        .code_len = try castLen(layout.code.len),
        .data_len = try castLen(layout.data.len),
        .entry_point = layout.entry_point,
        .import_table_len = @intCast(table_len),
    }, dest[0..header_size]);

    var offset: usize = header_size;
    for (layout.imports) |import| {
        dest[offset] = @intCast(import.library.len);
        dest[offset + 1] = @intCast(import.symbol.len);
        dest[offset + 2] = import.arg_count;
        offset += 3;
        for (import.argTypes()) |arg_type| {
            dest[offset] = @intFromEnum(arg_type);
            offset += 1;
        }
        @memcpy(dest[offset..][0..import.library.len], import.library);
        offset += import.library.len;
        @memcpy(dest[offset..][0..import.symbol.len], import.symbol);
        offset += import.symbol.len;
    }

    @memcpy(dest[offset..][0..layout.code.len], layout.code);
    offset += layout.code.len;
    @memcpy(dest[offset..][0..layout.data.len], layout.data);
    return offset + layout.data.len;
}

fn importTableLen(imports: []const foreign.Import) Error!u32 {
    if (imports.len > foreign.max_imports) return error.TooManyForeignImports;

    var total: usize = 0;
    for (imports) |import| {
        if (import.library.len > foreign.max_name_len or import.symbol.len > foreign.max_name_len) {
            return error.ForeignNameTooLong;
        }
        if (import.arg_count > foreign.max_args) return error.TooManyForeignArguments;
        total += import.encodedSize();
    }
    return @intCast(total);
}

// Tests ----------------------------------------------------------------------

const testing = std.testing;

fn writeAlloc(layout: Layout) ![]u8 {
    const buffer = try testing.allocator.alloc(u8, try encodedSize(layout));
    errdefer testing.allocator.free(buffer);
    try testing.expectEqual(buffer.len, try write(layout, buffer));
    return buffer;
}

test "a container round-trips code, static data, imports and the entry point" {
    var import: foreign.Import = .{ .library = "user32.dll", .symbol = "MessageBoxA" };
    for ([_]foreign.ArgType{ .ptr, .cstr, .u32 }) |arg_type| try import.addArg(arg_type);

    const code = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    const data = "hi\x00";
    const bytes = try writeAlloc(.{
        .imports = &.{import},
        .code = &code,
        .data = data,
        .entry_point = 5,
    });
    defer testing.allocator.free(bytes);

    const image = try parse(bytes);
    try testing.expectEqual(Kind.current, image.kind);
    try testing.expect(image.kind.separatesData());
    try testing.expectEqual(version, image.header.format_version);
    try testing.expectEqual(@as(u32, 5), image.header.entry_point);
    try testing.expectEqual(@as(u8, 1), image.header.import_count);
    try testing.expectEqualSlices(u8, &code, image.code);
    try testing.expectEqualStrings(data, image.data);
    try testing.expectEqual(code.len + data.len, image.imageLen());

    var iterator = image.importIterator();
    const decoded = (try iterator.next()).?;
    try testing.expectEqualStrings("user32.dll", decoded.library);
    try testing.expectEqualStrings("MessageBoxA", decoded.symbol);
    try testing.expectEqualSlices(foreign.ArgType, &.{ .ptr, .cstr, .u32 }, decoded.argTypes());
    try testing.expectEqual(@as(?foreign.Import, null), try iterator.next());
}

test "the header occupies its documented layout" {
    const bytes = try writeAlloc(.{ .code = &[_]u8{ 0, 0, 0 }, .data = "xy", .entry_point = 2 });
    defer testing.allocator.free(bytes);

    try testing.expectEqualStrings("VIGF", bytes[0..4]);
    try testing.expectEqual(version, bytes[offset_version]);
    try testing.expectEqual(@as(u8, 0), bytes[offset_flags]);
    try testing.expectEqual(@as(u8, 0), bytes[offset_import_count]);
    try testing.expectEqual(@as(u8, 0), bytes[offset_reserved]);
    try testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[offset_code_len..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[offset_data_len..][0..4], .little));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[offset_entry_point..][0..4], .little));
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[offset_import_table_len..][0..4], .little));
    try testing.expectEqual(@as(usize, header_size + 5), bytes.len);
}

test "headerless bytes parse as a raw code image" {
    const image = try parse(&[_]u8{ 0, 1, 2 });
    try testing.expectEqual(Kind.raw, image.kind);
    try testing.expect(!image.kind.separatesData());
    try testing.expectEqual(@as(usize, 3), image.code.len);
    try testing.expectEqual(@as(usize, 0), image.data.len);
    try testing.expectEqual(@as(u8, 0), image.header.import_count);
}

test "version 1 containers still parse, with code and data in one region" {
    // Magic, version 1, one import, then `lstrlenA` and two code bytes.
    const bytes = "VIGF" ++ [_]u8{ 1, 1, 12, 8, 1, @intFromEnum(foreign.ArgType.cstr) } ++
        "kernel32.dlllstrlenA" ++ [_]u8{ 24, 0 };

    const image = try parse(bytes);
    try testing.expectEqual(Kind.legacy, image.kind);
    try testing.expect(!image.kind.separatesData());
    try testing.expectEqual(@as(u32, 2), image.header.code_len);
    try testing.expectEqualSlices(u8, &[_]u8{ 24, 0 }, image.code);
    try testing.expectEqual(@as(usize, 0), image.data.len);

    var iterator = image.importIterator();
    const decoded = (try iterator.next()).?;
    try testing.expectEqualStrings("kernel32.dll", decoded.library);
    try testing.expectEqualStrings("lstrlenA", decoded.symbol);
    try testing.expectEqualSlices(foreign.ArgType, &.{.cstr}, decoded.argTypes());
}

test "a truncated version 1 import table is rejected" {
    const bytes = "VIGF" ++ [_]u8{ 1, 1, 12, 8, 0 } ++ "kernel32.dll";
    try testing.expectError(error.InvalidContainerHeader, parse(bytes));
}

test "unreadable containers are rejected rather than guessed at" {
    var buffer: [header_size]u8 = undefined;
    // A header describing an empty program: valid on its own, so each mutation
    // below is the only reason its container is rejected.
    writeHeader(.{}, &buffer);
    const good = buffer;

    try testing.expectError(error.InvalidContainerHeader, parse(buffer[0 .. header_size - 1]));

    // An unknown format version.
    buffer = good;
    buffer[offset_version] = 3;
    try testing.expectError(error.UnsupportedContainerVersion, parse(&buffer));

    // A flag bit this version does not define.
    buffer = good;
    buffer[offset_flags] = 1;
    try testing.expectError(error.UnsupportedContainerFlags, parse(&buffer));

    // Reserved bytes must be zero so they stay available.
    buffer = good;
    buffer[offset_reserved] = 1;
    try testing.expectError(error.InvalidContainerHeader, parse(&buffer));

    // More imports than the ABI allows.
    buffer = good;
    buffer[offset_import_count] = foreign.max_imports + 1;
    try testing.expectError(error.TooManyForeignImports, parse(&buffer));

    // Lengths that do not add up to the file size.
    buffer = good;
    std.mem.writeInt(u32, buffer[offset_code_len..][0..4], 99, .little);
    try testing.expectError(error.ContainerSizeMismatch, parse(&buffer));

    // An entry point outside the code region.
    var with_code: [header_size + 1]u8 = undefined;
    writeHeader(.{ .code_len = 1, .entry_point = 7 }, with_code[0..header_size]);
    with_code[header_size] = @intFromEnum(@import("opcode.zig").OpCode.halt);
    try testing.expectError(error.EntryPointOutOfRange, parse(&with_code));
}

test "an import table shorter than its declared length is rejected" {
    // Declare one import but leave the table empty.
    var buffer: [header_size]u8 = undefined;
    writeHeader(.{ .import_count = 1 }, &buffer);
    try testing.expectError(error.InvalidContainerHeader, parse(&buffer));
}

test "writing rejects layouts the format cannot express" {
    var buffer: [header_size + 8]u8 = undefined;
    // An entry point has to name an instruction in the code region.
    try testing.expectError(error.EntryPointOutOfRange, write(.{ .code = "", .entry_point = 1 }, &buffer));
    try testing.expectError(
        error.EntryPointOutOfRange,
        write(.{ .code = &[_]u8{0}, .entry_point = 1 }, &buffer),
    );

    const long_name: [foreign.max_name_len + 1]u8 = @splat('x');
    try testing.expectError(error.ForeignNameTooLong, encodedSize(.{
        .imports = &.{.{ .library = &long_name, .symbol = "s" }},
        .code = &[_]u8{0},
    }));

    const many: [foreign.max_imports + 1]foreign.Import = @splat(.{ .library = "k.dll", .symbol = "s" });
    try testing.expectError(error.TooManyForeignImports, encodedSize(.{ .imports = &many, .code = &[_]u8{0} }));

    try testing.expectError(error.BufferTooSmall, write(.{ .code = &[_]u8{0} }, buffer[0..header_size]));
}

test "the file-size bound covers the largest legal container" {
    const image_size = 4096;

    const library: [foreign.max_name_len]u8 = @splat('l');
    const symbol: [foreign.max_name_len]u8 = @splat('s');
    const code: [image_size]u8 = @splat(0);
    const many: [foreign.max_imports]foreign.Import = @splat(.{
        .library = &library,
        .symbol = &symbol,
        .arg_types = @splat(.u32),
        .arg_count = foreign.max_args,
    });

    try testing.expectEqual(maxFileSize(image_size), try encodedSize(.{
        .imports = &many,
        .code = &code,
    }));
}
