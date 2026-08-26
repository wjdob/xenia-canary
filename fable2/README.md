# Fable II profile

This keeps current Xenia Canary and ports only the old femtofork's useful
game-specific idea: selective readback for the known player/dog morph-texture
resolve. Canary's newer GPU downscaler handles 2x readback; the old CPU
downscaler and renderer plumbing were intentionally not copied.

## Build and run

```powershell
.\xb.ps1 build --config=release
.\fable2\run.ps1
```

A clean Windows build also needs the Vulkan shader tools described in
`docs/building.md`, even when the runtime profile uses D3D12. The validated
workspace has compatible local copies under the ignored `build/shader-tools`
directory.

Pass an ISO or `default.xex` path to launch it directly:

```powershell
.\fable2\run.ps1 "D:\Games\Fable II\default.xex"
```

The runner uses `fable2` as an isolated storage root. Copy an existing Fable II
save into `fable2/content` only after backing it up.

## Profiles

- `quality` (default): current Canary's `readback_resolve = "fast"`. This is
  the first profile to test and is expected to be the safest balance.
- `selective`: `readback_resolve = "none"` plus the title-scoped femtofork
  signature. It stalls only for the known morph resolve and should be tested
  after `quality` proves visually correct:

```powershell
.\fable2\run.ps1 -Profile selective
```

The selective address signature was originally validated by the femtofork on
the GOTY/Platinum executable. Treat other Fable II revisions as unverified and
start with `quality`.

## A/B/C UAT

These modes use the same selective profile and shader cache, force VSync on,
retain original MSAA, and apply the same enabled game patches:

```powershell
.\fable2\run.ps1 -Mode A "D:\Games\Fable II.iso" # 2x + CAS
.\fable2\run.ps1 -Mode B "D:\Games\Fable II.iso" # 1x + FSR
.\fable2\run.ps1 -Mode C "D:\Games\Fable II.iso" # 2x + CAS, previous-frame selective readback
```

Modes A and B use immediate selective readback. Mode C differs from A only by
using Canary's existing previous-frame readback buffer after the initial or
cache-miss synchronization. This avoids the immediate GPU queue wait but may
make the hero or dog morph data one frame stale. As with Canary's global fast
mode, the previous buffer isn't protected by an additional completion wait, so
Mode C remains experimental under heavy GPU load. Modes B and C use
command-line overrides, so they don't rewrite the selective config.

Warm the shader cache, then alternate A and C on the same route for at least two
runs each. Start at similar GPU temperatures and record minimum FPS, GPU usage,
temperature, and core clock. Keep C only for a repeatable improvement of at
least 10% with no hero, dog, makeup, clothing-menu, cutscene, colored-buffer, or
stability regression. Compare B separately as the lower-resolution baseline.

The `quality` and `selective` profile files use D3D12 RTV, 2x internal
resolution, synchronous shader compilation, and separate shader caches. Mode B
overrides the selective profile to 1x only for that launch. Synchronous
compilation may hitch when a shader first appears, but prevents Canary's
temporary blue, green, or black buffers caused by skipped draws while pipelines
compile.

`use_fuzzy_alpha_epsilon` is left off: it targets NVIDIA alpha-test flicker,
not opaque colored boxes, and can change transparency. `clear_memory_page_state`
is enabled because current Fable II reports associate it with reduced video
flicker.

## Test order

1. Start a new game with `quality`. Check the opening, first outdoor area,
   hero adulthood/makeup, dog appearance, and the clothing menu.
2. Repeat with `selective`. Compare frame pacing and the hero/dog textures.
3. If colored boxes remain, change `render_target_path_d3d12` to `"rov"` in a
   copied profile. ROV is slower but is the useful accuracy diagnostic.
4. If an issue occurs only at 2x, try `draw_resolution_scale_threshold = 80`,
   then `160`; this keeps small post-process targets at native resolution.
5. If 2x is too slow for the GTX 1660 Ti, set both resolution scales to `1`
   and change CAS to `"fsr"`.

Keep VSync, patches, and the test location unchanged during each comparison.
The current local patch file has the 600p fix, intro skip, 60 FPS, and High
Tick Rate enabled; all UAT modes leave them enabled. Keep `Disable Texture
Morphing` off once readback is confirmed working, since that patch
intentionally compromises morph appearance.
