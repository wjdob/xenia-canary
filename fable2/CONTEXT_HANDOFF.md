# Fable II / Xenia Canary context handoff

Last updated: 2026-08-25

Status: Three rounds of instrumented gameplay testing are done. The femtofork
selective readback never runs, and global readback does not fix the morph
textures either. The foliage halo and the texture flicker are both explained by
Fable II needing one CPU-GPU synchronization per frame. Range-filtered runs
showed four disjoint regions each fixing it, so the readback *data* is
irrelevant - `readback_resolve = "full"` was only ever an expensive way to buy
the stall. `await_gpu_completion_per_frame` now does it directly; it is built
but not yet tested in-game.

## Start here

- The user prefers Mode A's 2x image quality and wants a clean, stable target
  near 30 FPS on a GTX 1660 Ti laptop.
- `Disable Texture Morphing` is what fixes the black hero and dog textures —
  **not** the selective readback code, which never runs. Global readback has
  now been tested too and does not fix them either, so readback is not the
  mechanism and the femtofork port is dead weight.
- **The halo and the flicker are fixed by `readback_resolve = "full"`.** `none`
  gives a constant halo, `fast` makes it strobe at ~0.25 s with the dog in
  sync, `full` is clean. The `selective` profile now ships `"full"`. CAS and
  `draw_resolution_scale_threshold` are both ruled out — the threshold makes it
  far worse and must never be revisited.
- **The game needs one CPU-GPU sync per frame; the readback data is irrelevant.**
  Four disjoint readback ranges each fixed it, including the character mip
  chains, which cannot supply data that fixes a foliage halo. The new
  `await_gpu_completion_per_frame` buys that stall once per frame instead of
  once per resolve. **Untested in-game - that is the next run.**
- Best clean 2x result so far is ~17-18 FPS. 2x will not reach the ~30 target;
  1x plus a single per-frame stall is the configuration most likely to.
- The femtofork selective-readback port has been **deleted**. No Fable-specific
  code remains in `src/xenia/gpu`.
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
way the screenshot shows. This turned out to explain the flicker but not the
halo — see below.

## Round 2 results: two independent bugs, and readback is not the morph fix

| Run | Halo | Flicker |
|---|---|---|
| `-Mode A -RtPath rov` (cas, readback none, ROV) | **yes** | **no** |
| `-Profile quality` (no sharpening, readback fast, RTV) | **no** | **yes** |

The symptoms separate cleanly, so they are two different bugs.

### Flicker: the RTV path

ROV eliminated it. That matches the format-aliasing evidence directly — the
pixel-shader-interlock backend handles EDRAM aliasing correctly where the RTV
path has to fake the ownership transfer. ROV is far too slow to ship at 2x, so
the useful outcome here is a narrowed RTV bug, not a setting to adopt.

### The morph textures do not need readback

`-Morph on` with the `quality` profile — global `readback_resolve = "fast"`,
the only configuration that has ever actually performed a readback — still gave
a **black hero and dog**. Readback is not the mechanism.

That retires the entire femtofork premise. The selective-readback port cannot
be fixed by correcting its signature, because even unconditional readback
doesn't restore these textures. `Disable Texture Morphing` is the answer for
now, and the dead `fable2_selective_readback_resolve*` code should be removed
rather than left looking load-bearing.

Worth one confirming run before deleting anything: `-Readback full` (immediate
sync) rather than `fast`, with `-Morph on`. If that is also black, readback is
conclusively irrelevant.

### Halo: narrowed to two settings

The `quality` profile did not show the halo. It differs from Mode A in exactly
two respects — everything else in the two TOMLs is identical apart from the
cache root, vibration and window height:

| Setting | `quality` | `selective` / Mode A |
|---|---|---|
| `postprocess_scaling_and_sharpening` | `""` (bilinear) | `"cas"` |
| `readback_resolve` | `"fast"` | `"none"` |

`-Mode A -Sharpening bilinear` was run: **the halo was still there**, along
with the dog and texture flicker. CAS is ruled out, leaving
`readback_resolve = "none"`.

## Round 3: stale shared memory at 2x (superseded by Round 5)

The mechanism that fits every observation:

At 2x, a resolve writes the **scaled resolve buffer**, not guest-visible shared
memory. Guest memory for that address is only refreshed if `readback_resolve`
is on. When the texture cache later needs one of those surfaces and cannot
serve it from the scaled resolve buffer — which is exactly what happens for the
format-aliased destinations, since the buffer was written as `k_8_8_8_8` and is
being fetched as `k_2_10_10_10` or vice versa — it falls back to shared memory
and reads whatever stale bytes are there. That is the halo, and re-reading a
different stale variant frame to frame is the flicker.

It explains why `quality` (readback fast) is clean, why both Mode A variants
are not, and why ROV helped the flicker: ROV changes how EDRAM aliasing is
resolved, so fewer fetches take the broken fallback.

### Rejected: draw_resolution_scale_threshold

**`-ScaleThreshold 640` was tested and is catastrophically worse.** The whole
scene blows out to white, blue and magenta — far beyond the original halo —
though it does run much faster.

Why it fails: excluding surfaces by pitch puts some render targets at 2x and
others at 1x, and this game aliases EDRAM heavily (that is what the resolve
table showed). Ownership transfer between render targets of *different scales*
is where it comes apart. The mechanism applies at any threshold value, so 320
and 1024 are not worth trying either. **Do not revisit this setting for
Fable II.**

The blowout is itself informative: it looks like auto-exposure reading a
garbage value, which points at the small luminance/downsample buffers
(`0x1B648000` 32x16 `k_8`, the `k_32_FLOAT` 288x150 targets). Those are the
same small post-process surfaces implicated in the halo — the threshold turned
a subtle wrong-colour bug into a total exposure failure.

The reasoning below is kept only to explain why the idea looked good.

`draw_resolution_scale_threshold` keeps render targets at or below a given
surface pitch at native resolution, and
[d3d12_command_processor.cc:3228](../src/xenia/gpu/d3d12/d3d12_command_processor.cc#L3228)
confirms native resolves go **straight to shared memory** rather than the
scaled buffer. So excluding the small surfaces makes the fallback read correct
data with readback still off.

Every affected surface is small. From the resolve table, the format-aliased
post-process buffers have `surface_pitch` 160, 320, 560 and 640, and the
character mip chains have 80, 160 and 320. The main scene is 1120 and 1280.
A threshold of 640 covers all of them and leaves the scene at 2x:

```powershell
.\fable2\run.ps1 -Mode A -ScaleThreshold 640 -Quiet 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
```

The idea was that this would clear the halo with no readback stall and run
faster. The speed part held; the correctness part did not.

## Round 4: readback on — the halo now strobes, in sync with the dog

`-Mode A -Readback fast` changed the symptom rather than removing it. The
magenta/blue **flickers** instead of sitting there constantly, the dog flickers
**at the same time**, and the period is roughly 0.25 s.

Two things follow:

- Readback matters — it turned a constant fault into an intermittent one — but
  it is not sufficient.
- The halo and the character textures share one cause. Both are
  render-to-texture surfaces, and they now fail together on a common cycle.

### The fallback path, confirmed in code

[texture_cache.cc:626](../src/xenia/gpu/texture_cache.cc#L626) only reads a
texture out of the scaled resolve buffer when **all** of these hold:

1. resolution scaling is on,
2. the texture is tiled,
3. `IsScaledResolveSupportedForFormat(key)` — which on D3D12
   ([d3d12_texture_cache.cc:1338](../src/xenia/gpu/d3d12/d3d12_texture_cache.cc#L1338))
   means a **scaled load pipeline exists for that texture format**.

If any of them fails, `key.scaled_resolve` stays 0 and the texture is loaded
from **shared memory** instead. Shared memory holds that data only when
`readback_resolve` is on, and only at 1x. That is the fallback, and it is
completely silent.

## Round 5: `readback_resolve = "full"` fixes both — the remaining question is cost

`-Mode A -Readback full` produced a **clean image: no halo, no flicker**.

The full picture across every configuration tested:

| `readback_resolve` | Halo | Flicker |
|---|---|---|
| `none` | constant | yes |
| `fast` (previous frame) | strobes, ~0.25 s | yes, in sync with the halo |
| `full` (immediate sync) | **none** | **none** |

The progression is the diagnosis. A one-frame-stale value producing a ~0.25 s
oscillation, and a current value producing none, is a feedback loop settling:
something the guest reads back from resolved memory feeds the next frame's
lighting or exposure. Delay it by a frame and it rings; give it the current
value and it converges.

So the femtofork's *premise* was right after all — Fable II does consume resolve
results on the CPU — it was just aimed at the wrong resolve, and at the wrong
symptom. The morph textures never needed it; the lighting does.

### The texture-cache fallback was not involved

`log_unscaled_resolve_textures` reported nothing in that run. Note that the
first version of the flag had no way to distinguish "nothing happened" from
"the flag never bound", because the `CONFIG DUMP` echoes the config file rather
than the cvar registry. It now prints a one-shot

```
log_unscaled_resolve_textures is active - any texture read from shared memory
instead of the scaled resolve buffer will be reported below
```

so a null result can be trusted. **Re-confirm on the next run that this line is
present** before treating the absence of fallback reports as meaningful.

### Profile change

`fable2-2x-selective.config.toml` now ships `readback_resolve = "full"` instead
of `"none"`. The `"none"` was chosen to make room for selective readback code
that never executed, and it is the direct cause of the constant halo. A/B/C all
inherit this, so a plain `-Mode A` is now the clean configuration.

### Note: Xenia rewrites the profile TOMLs

`SetupConfig` points `config_path` at the file passed to `--config`, and
[xenia_main.cc:572](../src/xenia/app/xenia_main.cc#L572) calls
`config::SaveConfig()` on exit. So every run rewrites the profile: hex literals
become decimal, and newly registered cvars are appended. Command-line overrides
are *not* written back. Don't be surprised by a profile diff you didn't make.

## Round 6: the cost is the stall count, not the pixels

First frame rates recorded, all on the same route:

| Run | FPS | Visuals |
|---|---|---|
| 2x, `-Readback full` | ~10 | clean |
| 2x, `-Readback fast` | ~17 | halo + flicker |
| 1x (`-Mode B`), `-Readback full` | ~13 | clean |
| 2x, `readback none` (historical) | ~20 | halo + flicker |
| 1x, `readback none` (historical) | ~31 | halo + flicker |

`full` costs roughly half the frame rate, and **1x barely helps**: dropping to a
quarter of the pixels bought 3 FPS. So the cost is dominated by the number of
CPU-GPU synchronisation stalls, not by how much data moves or how much the GPU
draws. Correct but ~10 FPS is not shippable.

That points at exactly one optimisation: **stall for fewer resolves**. The
resolve table lists well over a hundred distinct destinations, and the guest
plainly does not read most of them back — the feedback loop that was ringing at
~0.25 s needs one value, not a hundred buffers.

## The general fix: a readback destination range

Two new cvars, general rather than title-specific:

- `readback_resolve_range_start`
- `readback_resolve_range_length` (0 = no restriction, the default)

A resolve is read back only if its written extent overlaps that region;
everything else takes the readback-disabled path, doing the resolve exactly as
before but skipping the stall. Both backends share one predicate in
[command_processor.cc](../src/xenia/gpu/command_processor.cc), with
compile-time checks for the overlap cases, and the first exclusion is logged
once so a misconfigured range is visible.

`-ReadbackRange "start,length"` on the launcher sets it; a bare `start` means a
1 MB window.

### Mode C is now the narrow-readback candidate

`-Mode C` is 2x + CAS with readback restricted to `0x1B600000 + 0x800000`.
That covers the cluster of small destinations the resolve table showed —
`0x1B648000` and `0x1B6F8000` are 32x16 `k_8`, i.e. 512 bytes each, the classic
shape of an auto-exposure average that the CPU reads. If the loop reads one of
those, Mode C is correct at nearly the cost of no readback at all.

```powershell
.\fable2\run.ps1 -Mode C -Readback full -Quiet 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
```

Note `-Readback full` is still needed: the range says *which* resolves are read
back, `readback_resolve` says *how*. The profile already ships `full`, so a
plain `-Mode C` also works.

### If Mode C is still wrong, bisect

The candidate regions, in the order worth trying — each is one run, and the
question each time is only "halo and flicker gone?":

| Range | What is in it |
|---|---|
| `0x1B600000,0x800000` | small 32x16-64x64 destinations (Mode C default) |
| `0x1A100000,0x100000` | the `k_32_FLOAT` 288x150 pair, a likely luminance buffer |
| `0x19E00000,0x400000` | the `k_16_16_16_16_FLOAT` HDR scene buffers |
| `0x12A00000,0x400000` | the post-process pyramid, incl. the format-aliased ones |
| `0x12700000,0x300000` | the character mip chains |
| `0x1ED00000,0x100000` | the final 1280x720 frame buffer |

If none of them alone is enough, widen: `0x12000000,0x10000000` covers
everything and should behave exactly like unrestricted `full`, which confirms
the filter itself is sound before bisecting further.

Record each run's FPS and verdict in [UAT_RESULTS.md](UAT_RESULTS.md).

## The femtofork port has been removed

With the signature proven never to match, and readback proven not to fix the
morph textures, `fable2_selective_readback_resolve`, its `_fast` and `_dest`
companions, and the whole title-scoped signature are deleted. There is no
Fable-specific code left in `src/xenia/gpu`.

What survives from that work, because it earned its place and is general:

- `ReportReadbackResolveSkip` — the seven silent early exits in the readback
  path now say why they bailed.
- Per-slot submission fences on the readback buffers, fixing a torn/stale read
  in the global `readback_resolve = "fast"` path for every title.
- `log_resolves` (was `fable2_log_resolves`) — the resolve table that made this
  whole diagnosis possible, now for any title.
- `log_unscaled_resolve_textures`.
- The new readback range filter.

## Round 7: it is the stall, not the data

Six range-filtered runs at 2x:

| Range | Dests in range | FPS | Visuals |
|---|---|---|---|
| `0x1B600000,0x800000` (Mode C default) | 5, all load-time only | ~19-20 | **halo + flicker** |
| `0x1ED00000,0x100000` final frame buffer | 1 | ~17-18 | clean |
| `0x1A100000,0x100000` luminance pair | 3 | ~17-18 | clean |
| `0x19E00000,0x400000` HDR scene | 5 | ~13-14 | clean |
| `0x12A00000,0x400000` post-process pyramid | 15 | ~12-13 | clean |
| `0x12700000,0x300000` character mip chains | ~80 | ~12-13 | clean |

Four **disjoint** regions each fix it completely. Reading back the character
mip chains cannot possibly supply data that fixes a foliage halo, so this is
not a data dependency at all.

What every clean run shares is that at least one resolve *per frame* falls in
the region, and the readback path calls `AwaitAllQueueOperationsCompletion()` —
a full GPU idle. The one broken run, `0x1B600000`, contains only destinations
resolved once at load, so nothing stalls during gameplay, and its ~19-20 FPS
matches `readback_resolve = "none"` exactly.

Frame rate tracks the number of resolves in range, confirming again that cost
is per-stall.

**So Fable II needs a CPU-GPU synchronization once per frame. The readback data
is irrelevant; `readback_resolve = "full"` was only ever an accidental way of
buying that stall, at a hundred times the necessary price.**

## `await_gpu_completion_per_frame`

A new general cvar waits for the GPU to go idle once at the end of each frame,
in both backends. That is one stall per frame instead of one per resolve, and
it needs no readback at all.

```powershell
.\fable2\run.ps1 -Mode A -Readback none -SyncPerFrame true -Quiet 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
```

Expected: clean, and at or above the ~17-18 FPS of the cheapest range-filtered
run, because it skips the readback copy entirely. If it is clean, this is the
answer for the title and readback can go back to `"none"`.

If it is **not** clean, then the stall's *position within the frame* matters
rather than merely happening once, and the cheapest correct configuration is
the range filter on the final frame buffer:
`-ReadbackRange "0x1ED00000,0x100000"`.

### Then chase the frame rate at 1x

The user's target is roughly 30 FPS, and 2x will not reach it either way — the
best clean 2x result so far is ~17-18. 1x with `readback none` historically ran
~31, so 1x plus a single per-frame stall is the configuration most likely to
land near the target:

```powershell
.\fable2\run.ps1 -Mode B -Readback none -SyncPerFrame true -Quiet 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
.\fable2\run.ps1 -Mode B -ReadbackRange "0x1ED00000,0x100000" -Quiet 'C:\Users\wdob\Desktop\Fable 2\Fable 2 PLT.iso'
```

Record both in [UAT_RESULTS.md](UAT_RESULTS.md), along with the 2x equivalents,
so the quality-versus-frame-rate decision is made on numbers.

### A caveat on the mechanism

Knowing that a per-frame stall fixes it is not the same as knowing *why*. A
missing synchronization somewhere in the RTV render target or texture path is
the obvious suspect, and forcing an idle papers over it. It is a legitimate
workaround, and cheap, but the underlying race is still unidentified — if a new
rendering fault appears later, that race is the first place to look. A
`xenia-gpu-d3d12-trace-viewer` capture (`-DXENIA_BUILD_MISC=ON`, **F4**) is the
tool for it.

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

### Readback destination range

`readback_resolve_range_start` and `readback_resolve_range_length` restrict
readback to one guest region; a resolve outside it takes the readback-disabled
path. Both backends share one predicate with compile-time overlap checks, and
the first exclusion is logged once.

The femtofork's title-scoped selective readback is gone - its signature never
matched, and readback does not fix the morph textures. See Round 6.

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
| `-Profile quality` | 2x | No configured sharpening | Global `fast` - strobes, see Round 5 |
| `-Profile selective` | 2x | CAS | Global `full` - the clean configuration |
| `-Mode A` | 2x | CAS | Global `full` |
| `-Mode B` | 1x | FSR | Global `full` |
| `-Mode C` | 2x | CAS | Global `full`; the selective-fast flag is inert |

The selective signature never matches, so A/B/C differ only in resolution and
sharpening. Do not read an A-vs-C result as a readback comparison; use
`-Readback` to vary readback deliberately.

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
command line: `-Readback none|fast|full`, `-ReadbackRange "start,length"`,
`-Sharpening bilinear|cas|fsr`, `-RtPath rtv|rov`, `-ScaleThreshold` (do not
use — see the rejected section), `-GammaAsUnorm16`, `-LogResolves`,
`-LogUnscaledTextures`, `-LogLevel`, `-Quiet`.

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

## Closed: the blue/pink foliage light

Resolved by `readback_resolve = "full"` — see Round 5. Kept here only so the
eliminated candidates aren't retried:

- **CAS** — ruled out. `-Mode A -Sharpening bilinear` still showed the halo.
- **`draw_resolution_scale_threshold`** — far worse, see the rejected section.
  Never revisit for this title.
- **Game MSAA** — the `Disable MSAA` patch made no difference either way, so
  the P1/P2/P3 render-config bisect was never needed and remains unrun.
- **The texture-cache shared-memory fallback** — `log_unscaled_resolve_textures`
  reported nothing, so no texture was taking that path.
- **ROV** — removes the flicker but not the halo, and is far too slow to ship.
  Useful only as an accuracy oracle.

Untried, and now unnecessary: `-GammaAsUnorm16 false`,
`mrt_edram_used_range_clamp_to_min = false`,
`depth_float24_convert_in_pixel_shader`, and a `xenia-gpu-d3d12-trace-viewer`
capture (`-DXENIA_BUILD_MISC=ON`, **F4**). Reach for the trace viewer first if a
new rendering fault appears — it would have identified this in one capture.

## Performance work — now the only open item

Correctness is settled, so everything below is about making `full` readback
affordable at 2x. **No frame rate has been recorded for any run yet**; that is
the first thing to fix.

- Measure `-Readback full` against `-Readback fast` at 2x, and `-Mode B` at 1x,
  into [UAT_RESULTS.md](UAT_RESULTS.md).
- If `full` at 2x is too slow, restrict readback to the destination range that
  actually matters rather than every resolve. Most of the hundred-plus
  destinations are certainly never read by the guest CPU. Bisect the address
  range; that is what the selective code should have been.
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
- Do **not** use `draw_resolution_scale_threshold` as a performance lever here,
  however tempting its speed is.

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
