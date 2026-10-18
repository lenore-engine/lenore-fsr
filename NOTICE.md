# Third-party code

This module builds AMD FidelityFX Super Resolution 3.1 from the FidelityFX SDK,
tag v1.1.4 (commit `c6efa6bf7f2027b3ec94f28578bb5965eabb9e55`), by Advanced
Micro Devices, Inc., under the MIT licence. It is fetched as a package pinned
in `build.zig.zon`, and `LICENSE.txt` at the package root is the text as it
shipped. Only the upscaler's host component, the shared helpers it calls and
its HLSL passes are compiled.

Three upstream files are compiled from a rewritten copy generated at build
time; the package itself is not modified. The edits are listed in `build.zig`
with the reason for each.

`src/compat/` and everything outside the package are ours and carry this
repository's licence.
