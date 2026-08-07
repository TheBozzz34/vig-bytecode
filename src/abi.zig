//! The execution ABI selected by a numbered VIG container or object.
//!
//! This module holds properties that must agree between the compiler, the
//! assembler, the linker, and the VM.  It deliberately does not describe raw
//! bytecode: raw bytecode predates profiles and is always VIG32.

const std = @import("std");

pub const Profile = enum(u8) {
    /// The established VIG ABI: 32-bit stack items, frame slots, and pointers.
    vig32 = 3,
    /// The new LP64 ABI: 64-bit stack items, frame slots, and guest pointers.
    vig64 = 4,

    pub fn containerVersion(self: Profile) u8 {
        return @intFromEnum(self);
    }

    pub fn slotSize(self: Profile) usize {
        return switch (self) {
            .vig32 => 4,
            .vig64 => 8,
        };
    }

    pub fn pointerSize(self: Profile) usize {
        return self.slotSize();
    }

    /// VIG32 objects use version 1. VIG64 objects use version 2.
    pub fn objectVersion(self: Profile) u8 {
        return switch (self) {
            .vig32 => 1,
            .vig64 => 2,
        };
    }

    pub fn fromContainerVersion(value: u8) ?Profile {
        return std.enums.fromInt(Profile, value);
    }

    pub fn fromObjectVersion(value: u8) ?Profile {
        return switch (value) {
            1 => .vig32,
            2 => .vig64,
            else => null,
        };
    }
};

test "profiles have stable file versions and widths" {
    const testing = std.testing;
    try testing.expectEqual(@as(u8, 3), Profile.vig32.containerVersion());
    try testing.expectEqual(@as(u8, 4), Profile.vig64.containerVersion());
    try testing.expectEqual(@as(usize, 4), Profile.vig32.slotSize());
    try testing.expectEqual(@as(usize, 8), Profile.vig64.slotSize());
    try testing.expectEqual(@as(u8, 1), Profile.vig32.objectVersion());
    try testing.expectEqual(@as(u8, 2), Profile.vig64.objectVersion());
}

test "profile lookup refuses unknown versions" {
    const testing = std.testing;
    try testing.expectEqual(Profile.vig32, Profile.fromContainerVersion(3).?);
    try testing.expectEqual(Profile.vig64, Profile.fromContainerVersion(4).?);
    try testing.expect(Profile.fromContainerVersion(2) == null);
    try testing.expectEqual(Profile.vig32, Profile.fromObjectVersion(1).?);
    try testing.expectEqual(Profile.vig64, Profile.fromObjectVersion(2).?);
    try testing.expect(Profile.fromObjectVersion(3) == null);
}
