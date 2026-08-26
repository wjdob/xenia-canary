# Fable II / Xenia Canary context handoff

Last updated: 2026-08-25

Status: The instrumented build has been run in-game. It showed that the
femtofork selective readback signature never matches, so that code has never
executed. The evidence also points at a concrete cause for the magenta/blue
foliage halo and the texture flicker. See the diagnostic result below.

## Start here

- The user prefers Mode A's 2x image quality and wants a clean, stable target
  near 30 FPS on a GTX 1660 Ti laptop.
- `Disable Texture Morphing` is what fixes the black hero and dog textures —
  **not** the selective readback code, which has now been proven never to run.
- The magenta/blue halo behind foliage and the random texture flicker are most
  likely one bug: the post-process pyramid aliases `k_8_8_8_8` and
  `k_2_10_10_10` views of the same memory.
  Disabling the `Disable MSAA` patch alone did not fix the halo, which is
  consistent — the aliasing has nothing to do with MSAA.
- The additional enabled patches were added manually and intentionally. Do not
  revert them as accidental cleanup.
- Work lives on branch `fable2-custom` and is committed.

## Diagnostic result: the selective readback has never run

The instrumented run answered the morph question outright.

- **No `signature matched` line.** The femtofork's destination `0x12704000` is
  not a resolve destination in this build at all.
- **No skip reports.** The readback path was never even entered, which follows:
  the signature didn't match, so the effective mode stayed `kDisabled`.

Consequences that invalidate earlier conclusions:

1. `fable2_selective_readback_resolve` has been dead code the whole time. The
   `selective` profile is behaviourally identical to plain
   `readback_resolve = "none"`.
2. **Modes A, B and C differ only in resolution and sharpening.** The
   "immediate selective readback" and "previous-frame selective readback"
   labels describe something that never happened, and the A-vs-C comparison the
   old handoff kept asking for could never have shown a difference.
3. The black hero and dog were always going to need the patch, because nothing
   else was running.

`-ResolveDest` cannot rescue this: the resolves near `0x1270xxxx` are
`k_1_5_5_5`, and the signature also requires `k_8_8_8_8`. It is the wrong
signature, not just the wrong address.

### What the game actually resolves

`0x1270C000`-`0x12965000` holds about twenty 4-level mip chains
(256x256 -> 128x128 -> 64x64 -> 32x32) in `k_1_5_5_5`, spaced 0x2B000 apart -
exactly one 16bpp 256x256 mip chain each. These are the render-to-texture
character textures, and they are the neighbourhood the femtofork was aiming at.

### The lead worth chasing: format aliasing in the post-process pyramid

Three destinations are resolved **at the same size with two different formats**:

| Destination | Size | Formats |
|---|---|---|
| `0x12CAB000` | 576x300 | `k_8_8_8_8` and `k_2_10_10_10` |
| `0x12D41000` | 640x360 | `k_8_8_8_8` and `k_2_10_10_10` |
| `0x12AE9000` | 288x150 / 576x300 | `k_8_8_8_8` and `k_2_10_10_10` |
| `0x12B16000` | 128x128 / 1120x600 | `k_8_8_8_8` and `k_8` |

640x360 is half of 1280x720; 576x300 is half of 1120x600; 288x150 is a quarter.
That is a bloom / light-shaft downsample pyramid, and the game writes the same
scratch buffer as both packed-LDR and packed-HDR.

Misinterpreting `k_2_10_10_10` as `k_8_8_8_8` scrambles channels in exactly the
way the screenshot shows - a magenta and blue halo where a warm sun glow
belongs - and serving whichever variant the cache happens to hold explains the
random texture flicker in the same run. One root cause, both symptoms, and
independent of the patch bundle.

### Next tests, in order

1. `-RtPath rov` - the decisive one. The pixel-shader-interlock backend handles
   EDRAM format aliasing correctly where RTV has to fake the transfer. If the
   halo and the flicker both go away, this is confirmed. Slow; a diagnostic,
   not a shipping setting.
2. `-Mode B` (1x) with everything else identical - separates resolution scaling
   from format aliasing.
3. `-GammaAsUnorm16 false` - cheaper and worth one run, though the aliasing
   evidence now points away from the gamma path specifically.
4. For the morph question, independent of the above:
   `.\fable2\patch-preset.ps1 -Morph on` then `-Profile quality` (global
   `readback_resolve = "fast"`). This is the only configuration that has ever
   actually performed readback. If the hero and dog render correctly, readback
   is what matters and a correct narrow signature can be built from the resolve
   table. If they are still black, readback was never the mechanism and the
   patch is the right answer.

Restore afterwards with `.\fable2\patch-preset.ps1 -Preset P0 -Morph off`.

## Goal and machine

The project blends current Xenia Canary with only the useful Fable II-specific
ideas from the old femtofork, without carrying its obsolete renderer plumbing.
The user prioritizes Mode A's rendering quality over Mode B's lower-resolution
performance.

- CPU: Intel Core i5-9300H
- GPU: NVIDIA GTX 1660 Ti 6 GB laptop GPU (reports ROV support)
- RAM: 32 GB
- Observed load: 4.8 GB VRAM, 0.2 GB shared GPU memory, 80 °C GPU,
  99-100% GPU usage, and about 60% aggregate CPU usage
- Current game path: `C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso`
- Supported title: Fable II GOTY/Platinum, title ID `4D5307F1`
- Patch executable hash: `4145F96D2DEE2AB5`

The 2x workload is GPU-bound. Removing a synchronization stall may improve
frame pacing, but it cannot guarantee a change from 20 to 30 FPS.

## Repository state

- Branch: `fable2-custom`, based on `canary_experimental` at `1e834f8a8`.
- `third_party/fmt` reports a dirty/untracked submodule state unrelated to this
  work. Preserve it.
- The old femtofork was researched but was not cloned into this repository.
- `xenia-build.py` needed a fix: since Python 3.14, `subprocess` no longer
  resolves a relative program named in a *string* command line on Windows, so
  both `vswhere` invocations failed with `FileNotFoundError` and no build was
  possible. They now pass argument lists.

## Implemented behavior

### Selective morph readback

The port keeps Canary's current scaled GPU downsampler and double-buffered
readback implementation. It does not copy the femtofork's old CPU downscaler or
large renderer changes.

The selector in [command_processor.cc](../src/xenia/gpu/command_processor.cc)
matches the Fable II morph resolve by:

- Title ID `0x4D5307F1`
- Rectangle-list primitive with 3 indices
- Copy destination `fable2_selective_readback_resolve_dest`
  (default `0x12704000`, `0` matches any)
- Valid color render-target source
- Destination format `8_8_8_8`

Cvars:

- `fable2_selective_readback_resolve`: enables readback only for that signature
  when global `readback_resolve = "none"`.
- `fable2_selective_readback_resolve_fast`: uses the alternating buffers for
  the matching resolve. Defaults to `false`.
- `fable2_selective_readback_resolve_dest`: the destination address to match.
- `fable2_log_resolves`: logs every distinct Fable II resolve signature.

Effective-mode precedence is centralized and compile-time asserted:

1. Global `readback_resolve = "fast"` or `"full"` wins unchanged.
2. Global readback disabled with no matching Fable resolve remains disabled.
3. A matching selective resolve is immediate/full by default.
4. A matching selective resolve becomes fast only when the new flag is true.

### Readback skip reporting

`IssueCopy_ReadbackResolvePath` has seven early exits that abandon the CPU
readback after the GPU resolve has already happened. Three logged nothing at
all; the rest used `XELOGGPU`, which is `LogLevel::Debug` and therefore
invisible at the profiles' `log_level = 2`. A game could get no readback
whatsoever with zero evidence in the log.

All seven now route through `CommandProcessor::ReportReadbackResolveSkip`,
which logs the first occurrence of each reason as a warning and then
rate-limits repeats. When the skipped resolve is the Fable II morph resolve,
the message says so explicitly. Both backends share the reporter.

### Mode C correctness (previously a known risk)

Canary's fast path rotated two buffers at guest-frame boundaries and waited
only for the initial allocation or a cache miss. It did not verify a completion
fence before the CPU mapped the alternate buffer, so with several frames in
flight the data could be stale or still being written.

`ReadbackBuffer` now records the submission that wrote each slot, and the
delayed read waits for exactly that submission before mapping. The submission
is already closed by then, so the wait is normally free. `submissions[i] == 0`
counts as a cache miss. This fixes the global `readback_resolve = "fast"`
default for every title, not just Mode C.

## Profiles and UAT modes

Do not confuse the named `quality` profile with the user's general preference
for Mode A quality. All lettered UAT modes use the `selective` profile and its
shader cache.

| Launch | Internal rendering | Final processing | Matching morph readback |
| --- | --- | --- | --- |
| `-Profile quality` | 2x | No configured sharpening | Global fast readback - the only mode that reads back anything |
| `-Profile selective` | 2x | CAS | Intended selective; **never matches, so none** |
| `-Mode A` | 2x | CAS | **None** (signature never matches) |
| `-Mode B` | 1x | FSR | **None** (signature never matches) |
| `-Mode C` | 2x | CAS | **None** (signature never matches) |

Until the signature is corrected, A/B/C differ only in resolution and
sharpening. Do not read an A-vs-C result as a readback comparison.

All A/B/C launches force `apply_patches = true`, `vsync = true`,
`framerate_limit = 0`, D3D12 RTV rendering, synchronous shader compilation, and
the same selective shader cache.

The profile files contain `vsync = false`, but the UAT command-line override
has higher priority. Xenia's log may print raw config text rather than
effective command-line values, so a logged `vsync = false` line alone does not
prove the UAT override failed. The launcher now prints a `Run manifest:` line
with the exact overrides it used — record that with each result.

### Launcher switches

[run.ps1](run.ps1) takes experiment overrides so a run is reproducible from one
command line: `-RtPath rtv|rov`, `-ScaleThreshold`, `-GammaAsUnorm16`,
`-LogResolves`, `-ResolveDest`, `-LogLevel`, `-Quiet`.

It no longer pipes the emulator through `Out-Host`. That pipe marshalled every
stdout log line synchronously through the PowerShell host — with `log_level = 2`
the game emits per-file I/O lines during play, so it was a real source of
frame-time noise in every number recorded so far. **Always use `-Quiet` for
measured runs.**

It uses `Start-Process -Wait` instead, which joins `-ArgumentList` with spaces
and does no quoting of its own. Every path in this workspace contains spaces,
so the launcher quotes each argument per the Windows CRT rules before handing
them over. Xenia silently ignores unrecognised flags, so a clean start is not
evidence that a flag name is right — check the `CONFIG DUMP` in the log, which
enumerates every registered cvar.

## Current intentional patch state

The active patch file is
[4D5307F1 - Fable II (GOTY_Platinum Edition, Femtofork Extras).patch.toml](<patches/4D5307F1 - Fable II (GOTY_Platinum Edition, Femtofork Extras).patch.toml>).
Every entry is currently enabled:

1. `600p Resolution (Fixes Strobe)`
2. `Skip intro videos`
3. `60 FPS`
4. `High Tick Rate`
5. A second `Skip intro videos` entry writing the same addresses
6. `Unlock Website Items`
7. `Disable Texture Morphing`
8. `Disable MSAA (Multi-Sample Anti-Aliasing)`
9. `Unlock Collectors Edition Content`

Inspect and toggle with [patch-preset.ps1](patch-preset.ps1), which only
touches the entries a preset names:

```powershell
.\fable2\patch-preset.ps1 -Show
.\fable2\patch-preset.ps1 -Preset P2
```

Important consequences:

- `Disable Texture Morphing` masks the behavior the selective readback code was
  intended to restore. Current testing therefore evaluates the patch workaround
  bundle, not morph-readback correctness.
- An earlier experimental MSAA-disabled Mode B produced graphical glitches.
  Watch specifically for their return.
- The duplicate intro patch is redundant but currently intentional state; do
  not clean it up as part of unrelated work.
- Website and Collector's Edition unlocks are content changes, not performance
  optimizations.

## Open investigation: the blue/pink foliage light

Bisect the render-config patches first — one variable per run, same save,
route, and camera:

| Preset | 600p | Disable MSAA | Note |
|--------|------|--------------|------|
| P0 | on | on | current state, baseline |
| P1 | on | off | already tested — no change |
| P2 | off | on | |
| P3 | off | off | closest to the stock render config |

`600p` writes `0x58` at `0x8238df4f`; `Disable MSAA` writes `0x01` at
`0x8238df3f` — 16 bytes apart, almost certainly the same render-config
structure. `600p` exists to fix strobing under the game's *original* MSAA, so
with MSAA off it may no longer be helping. The two are not independent.

Then emulator knobs, one at a time, on the best patch combo, ranked by how
directly each targets "a bright buffer comes out the wrong colour":

1. `-GammaAsUnorm16 false` — top suspect. The cvar's own description warns
   about games switching between `8_8_8_8_GAMMA` and `8_8_8_8` views of the
   same EDRAM range, which is what a bloom/tone-map chain does, and the RTV
   path has to fake that transfer.
2. `-ScaleThreshold 80`, then `160` — keeps small bloom/light-shaft targets at
   native resolution. Doubles as the pending performance experiment.
3. `mrt_edram_used_range_clamp_to_min = false` — more accurate EDRAM extent
   estimation with multiple bound render targets.
4. `-RtPath rov` — the accuracy oracle. Slow, not a shipping setting, but if
   the artifact vanishes under ROV it is definitively an RTV ownership-transfer
   or format problem.
5. If ROV fixes it: `depth_float24_convert_in_pixel_shader = true` plus
   `depth_float24_round = true` on RTV, since ROV forces both — this isolates
   which half of ROV mattered.
6. `-Mode B` (1x) with everything else identical — separates "resolution
   scaling" from "everything else" in one run.

If the knob matrix is inconclusive, build the trace tooling with
`-DXENIA_BUILD_MISC=ON` (currently `OFF` in `build/CMakeCache.txt`), capture the
frame with **F4**, and step it in `xenia-gpu-d3d12-trace-viewer` to identify the
exact draw and render-target format.

## Performance work, once visuals settle

- `-ScaleThreshold 80` is the main GPU-side lever at 2x.
- The 60 FPS patch was locked in before any 2x measurement existed. GPU-bound
  near 20 FPS, an unlocked 60 target adds CPU and present work and destabilises
  pacing. Worth one A-mode run with it disabled, compared on **frame-time
  consistency**, not average FPS. The user's call either way.
- VRAM is at 4.8 GB of 6 GB with 0.2 GB spilled to shared memory.
  `texture_cache_memory_limit_render_to_texture = 24` is multiplied by scale
  area (~96 MB at 2x). Test `texture_cache_memory_limit_hard = 512`.
- `async_shader_compilation` is off because skipped draws cause coloured
  buffers — correct for a cold cache. On a warm cache with `store_shaders`
  already populated there is nothing left to skip; worth one measured run.

Record everything in [UAT_RESULTS.md](UAT_RESULTS.md).

## Completed validation

- Full Release build completed successfully, including D3D12 and Vulkan.
- Compile-time assertions cover disabled, immediate selective, delayed
  selective, global-fast, and global-full precedence, plus the new
  configurable-destination behaviour (matching address, non-matching address,
  and address filter disabled).
- The Release executable contains the new cvar symbols and log strings.
- Windows PowerShell 5.1 and PowerShell 7 both parse [run.ps1](run.ps1) and
  pass `-WhatIf` launches for every parameter set.
- `patch-preset.ps1` round-trips P0 → P3 → P0 with an empty `git diff`.
- Both profile TOMLs parse and carry the new cvars.

No automated check can replace gameplay UAT for the Fable-specific signature,
patch interactions, or the foliage light.

## Decisions already made

- Keep 60 FPS and High Tick Rate enabled by default, but measure the 60 FPS
  patch at 2x before treating it as settled.
- Keep D3D12 RTV for shipping; ROV is an accuracy diagnostic and is slower.
- Keep asynchronous shader compilation off on a cold cache.
- Keep `clear_memory_page_state = true`; disabling it risks Fable video or
  model corruption.
- Keep `use_fuzzy_alpha_epsilon = false`; it targets alpha-test flicker, not
  opaque colored boxes.
- Keep real `occlusion_query = "fast"`; fake results have higher culling,
  flare, and exposure risk with uncertain performance benefit.
- Keep `draw_resolution_scale_threshold = 0` for Mode C so it differs from A in
  only the readback flag.

## Relevant files

- [run.ps1](run.ps1): profile and A/B/C launcher, experiment switches
- [patch-preset.ps1](patch-preset.ps1): patch bisect presets
- [UAT_RESULTS.md](UAT_RESULTS.md): results log and procedure
- [README.md](README.md): user-facing setup and diagnostics
- [fable2-2x-selective.config.toml](fable2-2x-selective.config.toml): UAT profile
- [fable2-2x-quality.config.toml](fable2-2x-quality.config.toml): global-fast
  comparison profile
- [command_processor.cc](../src/xenia/gpu/command_processor.cc): cvars,
  signature, precedence, compile-time checks, and the readback reporters
- [d3d12_command_processor.cc](../src/xenia/gpu/d3d12/d3d12_command_processor.cc):
  primary GTX 1660 Ti backend
- [vulkan_command_processor.cc](../src/xenia/gpu/vulkan/vulkan_command_processor.cc):
  parity backend

## Build command

```powershell
.\xb.ps1 build --config=release
```

The runner uses `fable2` as an isolated storage root. Preserve saves and avoid
deleting `fable2/content`; back it up before any storage migration.
