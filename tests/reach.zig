const fsr = @import("lenore-fsr");

// What the compiler would otherwise never look at.
//
// A test reaches only what it calls, and everything here needs a device to
// call. Referencing a function compiles its body; `Backend.interface` names
// every callback, so referencing it compiles those too.
//
// Anything here that gains a test which actually calls it should lose its line.

test "the device-facing surface is compiled" {
    _ = &fsr.Upscaler.init;
    _ = &fsr.Upscaler.deinit;
    _ = &fsr.Upscaler.setTuning;
    _ = &fsr.Upscaler.dispatch;
    _ = &fsr.supportsStorageWithoutFormat;

    _ = &fsr.Backend.init;
    _ = &fsr.Backend.deinit;
    _ = &fsr.Backend.interface;
    _ = &fsr.Backend.beginDispatch;
}
