const std = @import("std");
const fsr = @import("lenore-fsr");

const testing = std.testing;

test "the jitter cycle lengthens with the square of the upscale ratio" {
    // FidelityFX: 8 times the ratio squared, rounded down. At 0.75 that is
    // 8 * (4/3)^2 = 14.2.
    try testing.expectEqual(@as(u32, 14), fsr.jitterPhaseCount(1920, 2560));
    try testing.expectEqual(@as(u32, 8), fsr.jitterPhaseCount(2560, 2560));
}

test "jitter offsets stay inside the pixel and wrap with the cycle" {
    const phases = fsr.jitterPhaseCount(1920, 2560);
    for (0..phases) |i| {
        const offset = fsr.jitterOffset(@intCast(i), phases);
        for (offset) |component| try testing.expect(component >= -0.5 and component < 0.5);
    }
    try testing.expectEqual(fsr.jitterOffset(3, phases), fsr.jitterOffset(3 + phases, phases));
}
