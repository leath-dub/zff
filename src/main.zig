const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Self = @This();

const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;

const Pixel = @Vector(4, u16);

allocator: Allocator,
width: u32,
height: u32,
pixels: []Pixel,

pub fn decode(allocator: Allocator, data: []const u8) !Self {
    assert(data.len >= 16); // farbfeld has 16 bytes of metadata

    const magic_value = data[0..8];
    assert(mem.eql(u8, magic_value, "farbfeld"));

    const width = mem.readIntSliceBig(u32, data[8..12]);
    const height = mem.readIntSliceBig(u32, data[12..16]);

    const rest = data[16..];

    var pixels = ArrayList(Pixel).init(allocator);
    var window = mem.window(u8, rest, @sizeOf(Pixel), 1);

    var x = false;

    while (window.next()) |raw_pix| {
        var pix: Pixel = .{ 0, 0, 0, 0 };

        pix[0] = mem.readIntSliceBig(u16, raw_pix[0 .. 0 + 2]);
        pix[1] = mem.readIntSliceBig(u16, raw_pix[1 .. 1 + 2]);
        pix[2] = mem.readIntSliceBig(u16, raw_pix[2 .. 2 + 2]);
        pix[3] = mem.readIntSliceBig(u16, raw_pix[3 .. 3 + 2]);

        if (x) {
            std.debug.print("{} {} {} {}\n", .{ pix[0], pix[1], pix[2], pix[3] });
            x = true;
        }

        try pixels.append(pix);
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .pixels = try pixels.toOwnedSlice(),
    };
}

pub fn ByteInt(comptime T: type) type {
    return [@divExact(@typeInfo(T).Int.bits, 8)]u8;
}

// const result = try allocator.alloc(u8, 32 + (self.width * self.height * 64));
pub fn encode(self: *const Self, allocator: Allocator) ![]u8 {
    var result = ArrayList(u8).init(allocator);
    try result.appendSlice("farbfeld");

    var width: ByteInt(u32) = undefined;
    mem.writeIntBig(u32, &width, self.width);
    try result.appendSlice(&width);

    var height: ByteInt(u32) = undefined;
    mem.writeIntBig(u32, &height, self.height);
    try result.appendSlice(&height);

    for (self.pixels) |pix| {
        for (@as([4]u16, pix)) |n| {
            var pix_comp: ByteInt(u16) = undefined;
            mem.writeIntSliceBig(u16, &pix_comp, n);
            try result.appendSlice(&pix_comp);
        }
    }

    return result.toOwnedSlice();
}

pub fn deinit(self: *const Self) void {
    self.allocator.free(self.pixels);
}

test "Test decode" {
    const image = try Self.decode(testing.allocator, @embedFile("cat"));
    defer image.deinit();
}

test "Test encode" {
    // Create 500 * 500 image of just red colored pixels
    var image: Self = undefined;
    image.allocator = testing.allocator;
    image.width = 500;
    image.height = 500;

    var pixels = ArrayList(Pixel).init(testing.allocator);
    for (0..image.width * image.height) |_| {
        try pixels.append(.{ std.math.maxInt(u16), 0, 0, std.math.maxInt(u16) });
    }
    defer pixels.deinit();

    image.pixels = pixels.items;

    var encoded_bytes = try image.encode(testing.allocator);
    defer testing.allocator.free(encoded_bytes);
}
