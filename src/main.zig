const std = @import("std");

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Float = std.meta.Float;

const testing = std.testing;
const assert = std.debug.assert;
const mem = std.mem;
const math = std.math;

// Safe cast of integer from any size to another size, assuming both integers are not greater than 32 bits ( they can be any lower than that )
pub inline fn castIntNormal(comptime From: type, comptime To: type, value: From) To {
    const maxf_src = @as(f64, @floatFromInt(math.maxInt(From)));
    const maxf_dst = @as(f64, @floatFromInt(math.maxInt(To)));
    return @intFromFloat(@round((@as(f64, @floatFromInt(value)) / maxf_src) * maxf_dst));
}

pub fn Chunks(comptime T: type) type {
    return struct {
        index: ?usize,
        buffer: []const T,
        size: usize,

        pub inline fn first(self: *const @This()) []const T {
            std.debug.assert(self.index.? == 0);
            return self.next().?;
        }

        pub inline fn next(self: *@This()) ?[]const T {
            if (self.buffer[self.index.? * self.size ..].len == 0) return null;
            defer self.index.? += 1;
            return self.buffer[self.index.? * self.size .. (self.index.? + 1) * self.size];
        }

        pub inline fn reset(self: *@This()) void {
            self.index = 0;
        }
    };
}

pub fn chunks(comptime T: type, buffer: []const T, size: usize) Chunks(T) {
    std.debug.assert(size != 0);
    return .{
        .index = 0,
        .buffer = buffer,
        .size = size,
    };
}

pub fn Farbfeld(comptime Int: type) type {
    if (@typeInfo(Int).Int.bits >= 64) {
        @compileError("This image encoder and decoder only supports images with pixel data values of integer type with bits < 64");
    }

    return struct {
        pub const Pixel = @Vector(4, Int);

        allocator: Allocator,
        width: u32,
        height: u32,
        pixels: []Pixel,

        pub fn decode(allocator: Allocator, data: []const u8) !@This() {
            assert(data.len >= 16); // farbfeld has 16 bytes of metadata

            const magic_value = data[0..8];
            assert(mem.eql(u8, magic_value, "farbfeld"));

            const width = mem.readIntSliceBig(u32, data[8..12]);
            const height = mem.readIntSliceBig(u32, data[12..16]);

            const rest = data[16..];

            var pixels = ArrayList(Pixel).init(allocator);
            var chunksi = chunks(u8, rest, @sizeOf(@Vector(4, u16)));

            while (chunksi.next()) |raw_pix| {
                var pix: Pixel = .{ 0, 0, 0, 0 };
                var sub_chunksi = chunks(u8, raw_pix, 2);

                while (sub_chunksi.next()) |raw_pix_comp| {
                    pix[sub_chunksi.index.? - 1] = if (Int == u16) mem.readIntSliceBig(u16, raw_pix_comp) else castIntNormal(u16, Int, mem.readIntSliceBig(u16, raw_pix_comp));
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

        pub fn ByteInt(comptime T: type) @TypeOf([@divExact(@typeInfo(T).Int.bits, 8)]u8) {
            return [@divExact(@typeInfo(T).Int.bits, 8)]u8;
        }

        // const result = try allocator.alloc(u8, 32 + (self.width * self.height * 64));
        pub fn encode(self: *const @This(), allocator: Allocator) ![]u8 {
            var result = ArrayList(u8).init(allocator);
            try result.appendSlice("farbfeld");

            var width: ByteInt(u32) = undefined;
            mem.writeIntBig(u32, &width, self.width);
            try result.appendSlice(&width);

            var height: ByteInt(u32) = undefined;
            mem.writeIntBig(u32, &height, self.height);
            try result.appendSlice(&height);

            for (self.pixels) |pix| {
                if (Int == u16) { // What farbfeld natively uses, no need for casting
                    inline for (@as([4]u16, pix)) |n| {
                        var pix_comp: ByteInt(u16) = undefined;
                        mem.writeIntBig(u16, &pix_comp, n);
                        try result.appendSlice(&pix_comp);
                    }
                } else {
                    inline for (@as([4]Int, pix)) |n| {
                        var pix_comp: ByteInt(u16) = undefined;
                        mem.writeIntBig(u16, &pix_comp, castIntNormal(Int, u16, n));
                        try result.appendSlice(&pix_comp);
                    }
                }
            }

            return result.toOwnedSlice();
        }

        pub fn deinit(self: *const @This()) void {
            self.allocator.free(self.pixels);
        }
    };
}

test "Test decode" {
    const image = try Farbfeld(u16).decode(testing.allocator, @embedFile("cat"));
    defer image.deinit();
}

test "Test decode u8 pixel values" {
    const image = try Farbfeld(u8).decode(testing.allocator, @embedFile("cat"));
    defer image.deinit();
}

test "Test encode" {
    // Create 500 * 500 image of just red colored pixels
    var image: Farbfeld(u16) = undefined;
    image.allocator = testing.allocator;
    image.width = 500;
    image.height = 500;

    var pixels = ArrayList(@TypeOf(image).Pixel).init(testing.allocator);
    for (0..image.width * image.height) |_| {
        try pixels.append(.{ std.math.maxInt(u16), 0, 0, std.math.maxInt(u16) });
    }
    defer pixels.deinit();

    image.pixels = pixels.items;

    var encoded_bytes = try image.encode(testing.allocator);
    defer testing.allocator.free(encoded_bytes);
}

test "Test encode u8 pixel values" {
    // Create 500 * 500 image of just red colored pixels
    var image: Farbfeld(u8) = undefined;
    image.allocator = testing.allocator;
    image.width = 500;
    image.height = 500;

    var pixels = ArrayList(@TypeOf(image).Pixel).init(testing.allocator);
    for (0..image.width * image.height) |_| {
        try pixels.append(.{ 0, 255, 0, 255 });
    }
    defer pixels.deinit();

    image.pixels = pixels.items;

    var encoded_bytes = try image.encode(testing.allocator);
    defer testing.allocator.free(encoded_bytes);
}

test "Test that decode and re-encode produces the same result" {
    const start_bytes = @embedFile("cat");
    const image = try Farbfeld(u16).decode(testing.allocator, start_bytes);
    defer image.deinit();

    const encoded_bytes = try image.encode(testing.allocator);
    defer testing.allocator.free(encoded_bytes);

    try testing.expect(mem.eql(u8, start_bytes, encoded_bytes));
}
