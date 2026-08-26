# Fable II / Xenia Canary context handoff

Last updated: 2026-08-25

Status: Experimental Mode C is implemented and the Release build passes. The
current manually expanded patch bundle is intentional, but no post-expansion
performance result has been recorded yet.

## Start here

- The user prefers Mode A's 2x image quality and wants a clean, stable target
  near 30 FPS on a GTX 1660 Ti laptop.
- Before the latest patch additions, the hero and dog had black textures in
  Modes A, B, and C. Immediate and delayed selective readback did not fix this
  fault by themselves.
- The additional enabled patches were added manually and intentionally. Do not
  revert them as accidental cleanup.
- The current [README](README.md) still describes the earlier four-patch,
  original-MSAA baseline. It does not match the current patch TOML.
- Mode C has compiled successfully, but still needs an A/C performance and
  visual comparison with the current patch set.

## Goal and machine

The project blends current Xenia Canary with only the useful Fable II-specific
ideas from the old femtofork, without carrying its obsolete renderer plumbing.
The user prioritizes Mode A's rendering quality over Mode B's lower-resolution
performance.

- CPU: Intel Core i5-9300H
- GPU: NVIDIA GTX 1660 Ti 6 GB laptop GPU
- RAM: 32 GB
- Observed load: 4.8 GB VRAM, 0.2 GB shared GPU memory, 80 C GPU,
  99-100% GPU usage, and about 60% aggregate CPU usage
- Current game path: `C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso`
- Supported title: Fable II GOTY/Platinum, title ID `4D5307F1`
- Patch executable hash: `4145F96D2DEE2AB5`

The 2x workload is GPU-bound. Removing a synchronization stall may improve
frame pacing, but it cannot guarantee a change from 20 to 30 FPS.

## Repository state

- Branch: `canary_experimental`
- HEAD: `1e834f8a8` (`[Emulator] Fixed regression related to relaunching games
  introduced in XContent change`)
- The Fable work is uncommitted.
- Five GPU source files are modified; the `fable2/` directory is untracked.
- `third_party/fmt` also reports a dirty/untracked submodule state unrelated to
  this work. Preserve it.
- The old femtofork was researched but was not cloned into this repository.
- Last successful binary:
  `build\bin\Windows\Release\xenia_canary.exe`, built 2026-08-24 23:50.

## Implemented readback behavior

The port keeps Canary's current scaled GPU downsampler and double-buffered
readback implementation. It does not copy the femtofork's old CPU downscaler or
large renderer changes.

The selector in [command_processor.cc](../src/xenia/gpu/command_processor.cc)
matches only the known Fable II morph resolve:

- Title ID `0x4D5307F1`
- Rectangle-list primitive with 3 indices
- Copy destination `0x12704000`
- Valid color render-target source
- Destination format `8_8_8_8`

Two opt-in cvars control it:

- `fable2_selective_readback_resolve`: enables readback only for that signature
  when global `readback_resolve = "none"`.
- `fable2_selective_readback_resolve_fast`: uses the existing alternating fast
  buffers for the matching resolve. It defaults to `false`.

Effective-mode precedence is centralized and compile-time asserted:

1. Global `readback_resolve = "fast"` or `"full"` wins unchanged.
2. Global readback disabled with no matching Fable resolve remains disabled.
3. A matching selective resolve is immediate/full by default.
4. A matching selective resolve becomes fast only when the new flag is true.

D3D12 passes one effective-mode snapshot through its readback helper. Vulkan
uses the same selector, so both backends remain behaviorally aligned.

## Profiles and UAT modes

Do not confuse the named `quality` profile with the user's general preference
for Mode A quality. All lettered UAT modes use the `selective` profile and its
shader cache.

| Launch | Internal rendering | Final processing | Matching morph readback |
| --- | --- | --- | --- |
| `-Profile quality` | 2x | No configured sharpening | Global fast readback; selective hack off |
| `-Profile selective` | 2x | CAS | Immediate selective readback |
| `-Mode A` | 2x | CAS | Immediate selective readback |
| `-Mode B` | 1x | FSR | Immediate selective readback |
| `-Mode C` | 2x | CAS | Previous-buffer selective fast readback |

All A/B/C launches force:

- `apply_patches = true`
- `vsync = true`
- `framerate_limit = 0`
- D3D12 RTV rendering
- Synchronous shader compilation
- The same selective shader cache

The profile files contain `vsync = false`, but the UAT command-line override
has higher priority. Xenia's log may print raw config text rather than effective
command-line values, so a logged `vsync = false` line alone does not prove the
UAT override failed.

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

These additions are intentional. Before they were added, the hero and dog were
black in A, B, and C. This means the custom selective readback path did not
solve the current game's morph-texture problem by itself.

Important consequences:

- `Disable Texture Morphing` masks or bypasses the behavior the selective
  readback code was intended to restore. Current testing therefore evaluates
  the patch workaround bundle, not pure morph-readback correctness.
- The launcher's `original MSAA` message and the README's original-MSAA claim
  are now stale because the patch file disables game MSAA.
- An earlier experimental MSAA-disabled Mode B produced graphical glitches.
  Watch specifically for their return, but do not disable the current patch
  without user direction.
- The duplicate intro patch is redundant but currently intentional state; do
  not clean it up as part of unrelated work.
- Website and Collector's Edition unlocks are content changes, not performance
  optimizations.

## UAT history

1. At 2x with VSync disabled and fuzzy alpha enabled, the old custom fork felt
   slightly slower but avoided Canary's black, green, and blue boxes. Canary
   felt faster but showed those colored buffers without the later fixes.
2. The selective profile subjectively ran better than the normal profile.
3. An early Mode A was more stable than an aggressive Mode B; B showed graphics
   glitches and A reached roughly 23 FPS at its low point.
4. After restoring safer Mode B settings and enabling 60 FPS plus High Tick
   Rate, Mode A reached roughly 20 FPS at its low point and Mode B roughly
   31 FPS.
5. The user chose to preserve Mode A's 2x quality for experimental Mode C.
6. Before the current manual patch additions, hero and dog textures were black
   in all three modes. Mode C therefore did not fix that visual fault alone.
7. No post-addition FPS result or complete visual result has been recorded.

The older 20/31 FPS comparison predates the current expanded patch state and
must not be treated as an apples-to-apples baseline for new runs.

## Completed validation

- Full Release build completed successfully, including D3D12 and Vulkan.
- Compile-time assertions cover disabled, immediate selective, delayed
  selective, global-fast, and global-full precedence.
- Windows PowerShell 5.1 and PowerShell 7 parsed [run.ps1](run.ps1) and passed
  A/B/C `-WhatIf` launches.
- Both profile TOMLs parse and default
  `fable2_selective_readback_resolve_fast` to `false`.
- The Release executable contains the new cvar symbol.
- `git diff --check` passes; Git prints only expected LF/CRLF warnings.
- An independent read-only review found no blocking or high-severity defects.

No automated check can replace gameplay UAT for the Fable-specific signature,
patch interactions, or previous-buffer correctness.

## Known Mode C risk

Canary's fast path rotates two buffers at guest-frame boundaries and waits only
for the initial allocation or a cache miss. It does not verify a completion
fence before the CPU maps the alternate buffer. With multiple frames in flight
on a saturated GPU, the selected data may be stale, older than one frame, or
still being written.

This can appear as hero/dog corruption, makeup or clothing issues, colored
buffers, flicker, or instability. A correctness-grade future implementation
would track the GPU submission associated with each buffer slot and consume
only completed data. That synchronization has not been added because Mode C is
an isolated experiment.

With `Disable Texture Morphing` enabled, the matching resolve may also stop
being performance-relevant. If A and C become identical, confirm whether the
signature is still hit before adding further tuning.

## Next UAT

Use the current patch state first; do not change another variable during the
comparison.

```powershell
.\fable2\run.ps1 -Mode A 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
.\fable2\run.ps1 -Mode C 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
```

Procedure:

1. Warm the shader cache with the route before recording results.
2. Alternate A/C/A/C using the same save, route, camera, output resolution, and
   driver settings.
3. Begin each measured pass at a similar GPU temperature to reduce laptop
   thermal-clock bias.
4. Record minimum FPS, preferably 1% low or frame time, GPU usage, GPU
   temperature, GPU core clock, VRAM, and CPU usage.
5. Confirm whether the current patches eliminate the black hero/dog textures.
6. Check hero, dog, morality/purity makeup, clothing menus, cutscenes, outdoor
   lighting, colored buffers, flicker, object pop-in, and crashes.
7. Retain Mode C only if it produces at least a repeatable 10% low-point
   improvement without a new regression beyond the patch bundle's known morph
   compromises.

Mode B remains the lower-resolution performance reference:

```powershell
.\fable2\run.ps1 -Mode B 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
```

## Decisions already made

- Keep 60 FPS and High Tick Rate enabled for all modes.
- Keep D3D12 RTV; ROV is an accuracy diagnostic and is slower.
- Keep asynchronous shader compilation off because skipped draws can create the
  colored buffers the user wants to avoid.
- Keep `clear_memory_page_state = true` because disabling it risks Fable video
  or model corruption.
- Keep `use_fuzzy_alpha_epsilon = false`; it targets alpha-test flicker, not
  opaque colored boxes.
- Keep real `occlusion_query = "fast"`; fake results have higher culling,
  flare, and exposure risk with uncertain performance benefit.
- Keep `draw_resolution_scale_threshold = 0` for Mode C so it differs from A in
  only the readback flag.
- Do not combine more experimental flags until the A/C result is known.

If Mode C has no useful gain, the safest separate 2x configuration experiment
identified so far is `draw_resolution_scale_threshold = 80`, which keeps only
very small render targets at native resolution. It has not been implemented as
part of Mode C.

## Relevant files

- [run.ps1](run.ps1): profile and A/B/C launcher
- [README.md](README.md): user-facing setup and the earlier baseline
- [fable2-2x-selective.config.toml](fable2-2x-selective.config.toml): UAT profile
- [fable2-2x-quality.config.toml](fable2-2x-quality.config.toml): global-fast
  comparison profile
- [command_processor.cc](../src/xenia/gpu/command_processor.cc): cvars,
  signature, precedence, and compile-time checks
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
