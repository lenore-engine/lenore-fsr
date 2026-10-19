const std = @import("std");

// Copies one file with exact-text replacements applied, or with none, for a
// file that has to sit beside a rewritten one for its includes to find it.
//
// Tooling for the build: it is how the FidelityFX sources are patched without
// touching the pinned package. Each <from> must occur exactly once in the input.
// A pin moved to a release whose text differs then fails the build here rather
// than leaving a replacement unapplied or applying it somewhere else.
//
// Usage: replace <in> <out> [<from> <to>]...

const usage = "usage: replace <in> <out> [<from> <to>]...\n";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var argv = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer argv.deinit();
    _ = argv.skip();

    var args: std.ArrayList([]const u8) = .empty;
    while (argv.next()) |arg| try args.append(arena, arg);
    if (args.items.len < 2 or args.items.len % 2 != 0) {
        std.debug.print(usage, .{});
        return error.InvalidUsage;
    }

    const in_path = args.items[0];
    const out_path = args.items[1];
    const pairs = args.items[2..];

    const cwd: std.Io.Dir = .cwd();
    var text = cwd.readFileAlloc(io, in_path, arena, .limited(16 << 20)) catch |err| {
        std.debug.print("cannot read {s}: {t}\n", .{ in_path, err });
        return err;
    };

    var i: usize = 0;
    while (i < pairs.len) : (i += 2) {
        const from = pairs[i];
        const to = pairs[i + 1];
        const count = std.mem.count(u8, text, from);
        if (count != 1) {
            std.debug.print("{s}: expected one occurrence of the text below, found {d}\n{s}\n", .{ in_path, count, from });
            return error.ReplacementNotUnique;
        }
        const at = std.mem.indexOf(u8, text, from).?;
        text = try std.mem.concat(arena, u8, &.{ text[0..at], to, text[at + from.len ..] });
    }

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = text });
}
