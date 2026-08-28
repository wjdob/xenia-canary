# Xenia Canary — Fable II investigation fork

A fork of [xenia-canary](https://github.com/xenia-canary/xenia-canary) built to
make **Fable II (GOTY/Platinum, title `4D5307F1`)** render correctly and run
acceptably on modest hardware.

Upstream's README is preserved as
[README-xenia-canary.md](README-xenia-canary.md). Build instructions are
unchanged — see [docs/building.md](docs/building.md).

This document is written for the next person who wants to push this further.
It records what was found, **how** it was found, and — just as importantly —
every approach that looked promising and turned out to be wrong.

---

## Update: upstream's EDRAM rework changed the picture

This fork now includes upstream commit `437a7280c`
*[GPU] Use EDRAM layout with a single sample addressing scheme*, which unifies
1x/2x/4x sample addressing and rewrites the render-target ownership transfers.
Its own message notes that the old layout "decodes intentionally aliased views
into shuffled images" - which is the class of bug documented below.

Measured on the merged tree **with the per-frame sync turned off**:

| Configuration | FPS | Visuals |
|---|---|---|
| **1x + FSR (`-Mode B`)** | **~30** | halo and dog extrusion gone |
| 2x + CAS (`-Mode A`) | ~20 | same |

So the foliage halo is fixed upstream, and the frame rate is well above where
the workaround left it (1x was ~26-30 with the sync, 2x ~16-17). **Both
profiles now default the sync off** - after this merge it fixes nothing here
and only costs frame rate - so a plain `-Mode A` or `-Mode B` is correct.

There are three separate defects; do not conflate their fixes:

- The **black hero and dog textures** require the `Disable Texture Morphing`
  game patch. Readback does not fix them.
- The **foliage halo** was fixed by upstream's single-sample EDRAM addressing.
- The remaining **dog artifact** is a vertex-mesh extrusion: a narrow triangle
  stretches from the dog toward the ground and flickers under camera motion.

The extrusion matches the
[old femtofork's documented Fable II issue](https://github.com/just-harry/unofficial-xenia-femtofork-for-fable-ii#issues-not-solved). A
[newer game-specific fork](https://github.com/SadTransGirl/xenia-canary-GummiFableII/blob/canary_experimental/CHANGES.md#fable-ii-fixes)
skips the redundant draw using vertex shader `7C5710DEF3EE33C4`, and that
shader is present in this repository's RenderDoc export. This fork therefore
has a D3D12 workaround, `fable2_dog_mesh_fix`. Its global default remains off,
but the control/candidate matrix passed and both Fable profiles enable it.

### The dog artifact and proven workaround

What is left is a thin dark wedge, roughly two pixels wide, extruded from the
dog mesh toward the ground. It is intermittent, worse under camera motion, and
purely cosmetic. Everything below was tested in-game and **does not fix it**:

| Tried | Result |
|---|---|
| `await_gpu_completion_per_frame = true` | no effect |
| `-Sharpening bilinear` (no FSR/CAS) | no effect — rules out sharpening amplification |
| `-ExactDepth24` | **worse** — widespread flicker, foliage through solid objects |
| `-RtPath rov` | **worse** — reintroduces the halo |
| `gamma_render_target_as_unorm16 = false` | no effect |
| `no_discard_stencil_in_transfer_pipelines = true` | no effect |
| `native_stencil_value_output = false` | no effect |

A RenderDoc capture established the exact path the final image takes:

```
RT Dump k_2_10_10_10 1xMSAA   host RT      -> EDRAM buffer
Resolve Copy Full 32bpp       EDRAM buffer -> guest RAM (0x1ED02000)
Dispatch(40, 23, 1)           guest RAM    -> staging buffer
CopyTextureRegion             staging      -> loaded framebuffer texture
Dispatch(80, 90, 1)           that texture -> presenter guest output
DrawInstanced(4, 1)           FSR EASU     -> swapchain
```

The load's `guest_offset` root constant reads **`0x1ED02000`**, matching the
`log_resolves` table exactly — so the capture and the log evidence describe the
same thing.

**Two caveats a successor must know.** The intermediate textures in that chain
were read as "clean" at default zoom, but a two-pixel line is not visible at
that scale, so those readings should not be trusted — zoom to 400%+ on the dog
before concluding anything. And **two of two captured frames came out clean**
while the displayed image was glitched; RenderDoc serialises the frame it
captures, which is the same class of change as `await_gpu_completion_per_frame`,
so capturing may perturb the very bug being hunted.

The earlier shadow/depth and trace-viewer render-target theory is now
**superseded for this symptom**. Screenshots show geometry stretching from the
dog, and the matching shader skip is a narrower, testable explanation. The
RenderDoc chain above remains useful historical evidence for the final-image
path, but it did not identify the producer of the extrusion.

The direct control/candidate matrix kept patches and other settings unchanged:

```powershell
# Mode A control / candidate
.\fable2\run.ps1 -Mode A -Cvar fable2_dog_mesh_fix=false -Quiet "D:\Games\Fable II.iso"
.\fable2\run.ps1 -Mode A -Cvar fable2_dog_mesh_fix=true  -Quiet "D:\Games\Fable II.iso"

# Mode B control / candidate
.\fable2\run.ps1 -Mode B -Cvar fable2_dog_mesh_fix=false -Quiet "D:\Games\Fable II.iso"
.\fable2\run.ps1 -Mode B -Cvar fable2_dog_mesh_fix=true  -Quiet "D:\Games\Fable II.iso"
```

| Mode | Fix off | Fix on |
|---|---|---|
| A | extrusion present | extrusion absent, ~20 FPS |
| B | extrusion present | extrusion absent, ~30 FPS |

No new dog-geometry defect or performance regression was reported. The Fable
profiles now enable the workaround; `-Cvar fable2_dog_mesh_fix=false` is the
rollback.

### Periodic-stutter remediation

After the rendering fixes, both modes showed a micro-stutter roughly every
4–5 seconds even while standing still. At the start of this investigation,
local `HEAD` and `origin/fable2-custom` were identical at `7a3564620`, ruling
out an unpushed Claude runtime-source delta.

Two hidden build/runtime facts remained:

- Claude's build directory cached `XENIA_ENABLE_TRACE_WRITER=ON`. The executable
  was optimized Release, but unused F4 trace hooks were compiled into hot GPU
  paths. Clean Release builds now compile the internal writer out. F12
  screenshots and RenderDoc capture are unaffected; F4 is the separate
  Debug-only internal GPU trace.
- The log queued 532 cached pipeline descriptions, including 258 translations,
  on up to seven workers and launched the guest immediately despite the Fable
  profiles using `async_shader_compilation=false`. The old `0 ms` result only
  measured queueing.

This fork adds the general GPU cvar
`shader_storage_initialization_blocking` (default false). Both Fable profiles
set it true, keeping the initialization indicator active until warmed pipeline
work completes and logging the actual completion time before guest launch.
A/B/C rendering semantics do not change.

Preliminary Mode B UAT favors blocking initialization: both clean configurations
ran at roughly 35–50 FPS, but the non-blocking run dipped into the 20s more
often. This is subjective rather than formal acceptance; the preserved
trace-enabled boundary, timed alternating passes, and cadence/hitch metrics
remain open. Before testing, free at least 20 GB on `C:` while preserving the
ISO, saves, and warmed cache. See the [three-boundary matrix, metrics,
acceptance criteria, and evidence-gated
fallbacks](fable2/UAT_RESULTS.md#periodic-stutter-remediation-uat).

The `await_gpu_completion_per_frame` cvar stays in the tree because it is
general and was genuinely the fix before this merge. Everything below documents
how that pre-merge conclusion was reached, and remains accurate for that tree.

## The headline finding (pre-merge, historical)

**Fable II needs one CPU-GPU synchronization per frame.**

Without it, the light behind tree foliage renders magenta/blue and textures
flicker. With it, the image is correct. The synchronization is all that
matters — no data needs to be read back, no specific buffer needs to be
current.

This fork adds `await_gpu_completion_per_frame`, a general Xenia cvar that
waits for the GPU to go idle once at the end of each frame. It costs about
3-4 FPS. The previously-known way to get the same result — turning on
`readback_resolve = "full"` — costs roughly **half the frame rate**, because it
stalls once per resolve and the game issues well over a hundred distinct
resolves per scene.

If you are here because another title has unexplained flicker or wrong-colour
effects, **try `await_gpu_completion_per_frame = true` first.** It is not
Fable-specific.

---

## Results

GTX 1660 Ti laptop (6 GB), i5-9300H, 32 GB RAM. Same outdoor route each run,
warmed shader cache, patch preset P0.

| Configuration | FPS | Visuals |
|---|---|---|
| **1x + FSR, per-frame sync** (`-Mode B`) | **~26-30** | **clean** |
| 2x + CAS, per-frame sync (`-Mode A`) | ~16-17 | clean |
| 2x, `readback_resolve = "full"` | ~10 | clean |
| 2x, `readback_resolve = "fast"` | ~17 | halo + flicker |
| 2x, `readback_resolve = "none"`, no sync | ~20 | halo + flicker |
| 1x, `readback_resolve = "full"` | ~13 | clean |
| 1x, `readback_resolve = "none"`, no sync | ~31 | halo + flicker |

2x tops out around 16-17 FPS with a correct image. The per-frame sync costs only
3-4 FPS there — 2x rendering itself is what this GPU cannot afford. That is a
hardware limit, not a remaining bug.

---

## How the conclusion was reached

The path mattered, because three plausible hypotheses were wrong along the way.

### 1. The starting point was a dead port

This tree began as an attempt to port the
[unofficial femtofork for Fable II](https://github.com/just-harry/unofficial-xenia-femtofork-for-fable-ii)'s
"selective readback" idea onto current Canary: perform CPU readback only for
the one resolve that generates the player and dog morph textures, identified by
a register signature (rectangle-list primitive, 3 indices, destination
`0x12704000`, format `k_8_8_8_8`).

Instrumenting it showed **the signature never matched.** The code had never
executed. `0x12704000` is not a resolve destination in this build at all, so:

- the "selective" profile was behaviourally identical to plain
  `readback_resolve = "none"`;
- the A/B/C test modes, which supposedly differed in readback strategy,
  differed only in resolution and sharpening;
- the black hero and dog textures were always going to need a game patch,
  because nothing else was running.

Correcting the address would not have helped either: even **global**
`readback_resolve = "fast"` leaves the hero and dog black. Readback is simply
not the mechanism for the morph textures. The port has been deleted.

**Lesson:** the readback path had seven early exits that failed silently — three
logged nothing at all, and the rest used `XELOGGPU`, which is debug level and
therefore invisible at the default `log_level = 2`. A title could get no
readback whatsoever with zero evidence in the log. That is now fixed (see
[Diagnostics](#diagnostics)).

### 2. What the game actually resolves

With `log_resolves` the picture became concrete. Fable II issues ~130 distinct
resolve destinations. The interesting clusters:

| Region | Contents |
|---|---|
| `0x1270C000`–`0x12965000` | ~20 four-level mip chains, 256×256→32×32, `k_1_5_5_5` — the render-to-texture character textures |
| `0x12AE9000`, `0x12CAB000`, `0x12D41000` | bloom / light-shaft downsample pyramid (640×360, 576×300, 288×150) |
| `0x199E8000`, `0x19EE8000` | `k_16_16_16_16_FLOAT` HDR scene buffers |
| `0x1A1B3000`, `0x1A1E0000` | `k_32_FLOAT` 288×150, probably luminance |
| `0x1B648000`, `0x1B6F8000` | 32×16 `k_8` — 512 bytes each, the shape of an auto-exposure average |
| `0x1ED02000` | 1280×720 `k_8_8_8_8`, the final frame buffer |

Three post-process destinations are resolved **at the same size with two
different formats** — `k_8_8_8_8` and `k_2_10_10_10` at `0x12CAB000`,
`0x12D41000` and `0x12AE9000`. The game aliases the same scratch memory as both
packed-LDR and packed-HDR. This looked like a very strong explanation for
channel-scrambled magenta output. **It was not the cause of the halo**, though
it is real and is the best available explanation for the RTV-path flicker (ROV
eliminates that flicker; see [Dead ends](#dead-ends)).

### 3. The readback progression

| `readback_resolve` | Halo | Flicker |
|---|---|---|
| `none` | constant | yes |
| `fast` (previous frame) | strobes at ~0.25 s | yes, in sync with the halo |
| `full` (immediate sync) | none | none |

A one-frame-stale value producing a steady ~4 Hz oscillation, and a current
value producing none, reads like a feedback loop settling. That suggested the
guest was reading something back and feeding it into the next frame's lighting.

### 4. The experiment that overturned that

`readback_resolve = "full"` was then restricted to one guest address range at a
time, using the new `readback_resolve_range_start/length` cvars:

| Range | Resolve destinations in range | FPS | Visuals |
|---|---|---|---|
| `0x1B600000 + 0x800000` | 5, **all resolved once at load** | ~19-20 | halo + flicker |
| `0x1ED00000 + 0x100000` | 1 | ~17-18 | clean |
| `0x1A100000 + 0x100000` | 3 | ~17-18 | clean |
| `0x19E00000 + 0x400000` | 5 | ~13-14 | clean |
| `0x12A00000 + 0x400000` | 15 | ~12-13 | clean |
| `0x12700000 + 0x300000` | ~80 | ~12-13 | clean |

Four **disjoint** regions each fix it completely. Reading back the character mip
chains cannot possibly supply data that fixes a foliage halo, so this was never
a data dependency.

What every clean run shares is that **at least one resolve per frame** falls in
the region, and the readback path calls `AwaitAllQueueOperationsCompletion()` —
a full GPU idle. The one broken range contains only destinations resolved at
load time, so nothing stalls during gameplay, and its frame rate matches
`readback_resolve = "none"` exactly.

Frame rate tracks the *number* of resolves in range throughout, confirming the
cost is per-stall rather than per-byte.

Hence: the game needs a per-frame stall, and `readback_resolve = "full"` was an
accidental, hundredfold-overpriced way of buying one.

---

## Dead ends

Each of these was tested in-game and does **not** work. Recorded so nobody
spends another session on them.

| Approach | Result |
|---|---|
| **`draw_resolution_scale_threshold`** | **Catastrophic.** At 640 the whole scene blows out to white/blue/magenta — far worse than the original halo, though much faster. Mixing 2x and native render targets breaks this game's heavy EDRAM aliasing; ownership transfer between targets of *different scales* is where it fails. Applies at any threshold value. **Do not revisit.** |
| **CAS sharpening** | Not the cause. `-Sharpening bilinear` still shows the halo. |
| **Game MSAA / the 600p patch** | Neither affects the halo. The `Disable MSAA` and `600p Resolution` patches write 16 bytes apart in what is almost certainly the same render-config struct, so they are not independent — but the P0–P3 bisect turned out never to be needed. |
| **ROV (`render_target_path_d3d12 = "rov"`)** | Removes the texture flicker but **not** the halo, and is far too slow to ship. Useful only as an accuracy oracle: it does confirm the RTV path mishandles this game's EDRAM format aliasing. |
| **Texture-cache shared-memory fallback** | Not involved. `log_unscaled_resolve_textures` reported nothing — no texture was being read from shared memory instead of the scaled resolve buffer. |
| **Selective readback by resolve signature** | The femtofork signature never matches, and readback does not fix the morph textures at all. Deleted. |

Untried and now unnecessary for the historical halo investigation:
`gamma_render_target_as_unorm16 = false`,
`mrt_edram_used_range_clamp_to_min = false`,
`depth_float24_convert_in_pixel_shader`, and a
`xenia-gpu-d3d12-trace-viewer` capture (build Debug with
`-DXENIA_BUILD_MISC=ON`, capture with **F4**). These are not the next step for
the dog-mesh extrusion.

---

## What this fork changes in the emulator

Most changes below are general. The dog-mesh workaround is the sole
title-specific exception; its global default is off and the Fable profiles
enable it.

### `fable2_dog_mesh_fix` (D3D12 bool, default off)

For title `4D5307F1` only, skips the redundant draw whose vertex shader hash is
`7C5710DEF3EE33C4`. This is an opt-in workaround for the dog mesh extrusion;
it does not affect the morph-texture or foliage-halo fixes. The first skipped
draw is logged. The A/B matrix passed, so both Fable profiles set this true;
the cvar remains available for rollback.

### `shader_storage_initialization_blocking` (GPU bool, default off)

Controls whether persistent shader and pipeline-cache initialization runs in
the background or completes before guest module launch. Both modes retain the
same completion callback and log actual elapsed time. Canary's background
behavior remains the global default; both Fable profiles enable blocking
startup so cached pipeline workers do not overlap gameplay.

### `await_gpu_completion_per_frame` (bool, default off)

Waits for the GPU to go idle once at the end of every frame, in both the D3D12
and Vulkan backends. For titles that only render correctly when something
forces a CPU-GPU sync, this gives them one stall per frame instead of one per
resolve. It costs frames-in-flight, so it lowers the ceiling on GPU-bound
titles that do not need it.

### `gpu_frames_in_flight` (int, default -1 = backend default of 3)

Makes the depth of Xenia's existing frame throttle configurable. Setting it to
1 forces the same per-frame synchronization point by waiting for the *previous
frame* rather than a full GPU idle, which should be cheaper.
**This has not yet been tested in-game** — see [Open questions](#open-questions).

### `readback_resolve_range_start` / `readback_resolve_range_length`

Restricts CPU readback to a single guest region; resolves outside it take the
readback-disabled path, doing the resolve exactly as before but skipping the
stall. Readback cost scales with the *number* of resolves read back rather than
their size, so for a title that genuinely reads a few destinations back, this
keeps the correctness at a fraction of the price. Both backends share one
predicate with compile-time overlap checks.

### Readback skip reporting

`IssueCopy_ReadbackResolvePath` abandons the CPU readback at seven points
*after* the GPU resolve has already run. Three logged nothing at all; the rest
used `XELOGGPU` (debug level), invisible at the default log level. They now all
route through `CommandProcessor::ReportReadbackResolveSkip`, which names the
failing prerequisite, warns on first occurrence, and rate-limits repeats.

### Per-slot submission fences on readback buffers

`readback_resolve = "fast"` rotated two buffers at guest-frame boundaries and
waited only for the initial allocation or a cache miss — it never verified a
completion fence before the CPU mapped the alternate buffer. With several
frames in flight that could hand the guest a torn or stale buffer.
`ReadbackBuffer` now records the submission that wrote each slot and waits for
exactly that submission before mapping. It is already closed by then, so the
wait is normally free. **This fixes `readback_resolve = "fast"` for every
title**, not just this one.

### Diagnostics

- `log_resolves` — one line per distinct resolve signature (destination, size,
  primitive, index count, source select, destination format, surface pitch,
  MSAA), deduplicated. This is the table you pick a readback range from.
- `log_unscaled_resolve_textures` — with resolution scaling, logs textures whose
  guest memory a scaled resolve wrote but that cannot be read back out of the
  scaled resolve buffer, so they load from shared memory instead. It announces
  itself once when active, so a null result can be trusted.

### Build fix

`xenia-build.py` failed under Python 3.14, which no longer resolves a relative
program named in a *string* command line on Windows — both `vswhere` calls died
with `FileNotFoundError` and no build was possible. They now pass argument
lists.

---

## Running it

The `fable2/` directory is a self-contained profile, launcher and patch bundle.
See [fable2/README.md](fable2/README.md) for full detail.

```powershell
.\xb.ps1 build --config=release --force `
  --cmake-define XENIA_BUILD_MISC=OFF --target xenia-app
.\fable2\run.ps1 -Mode B "D:\Games\Fable II.iso"   # recommended
```

This clean Release path intentionally compiles out Xenia's F4 internal GPU
trace writer. F12 screenshots and `fable2/capture.ps1` RenderDoc capture remain
available.

If a build has to recompile the SPIR-V shaders, `VULKAN_SDK` must point at a
Vulkan SDK **even when you only run D3D12** — otherwise the shader step fails
with `FileNotFoundError`, because it falls back to bare tool names on `PATH`:

```powershell
$env:VULKAN_SDK = "C:\VulkanSDK\<version>"
```

`-Mode B` is 1x with FSR upscaling, not a plain resolution drop. `-Mode A` is 2x
with CAS if you prefer the image to the frame rate. `-Mode C` is Mode A plus a
readback-range preset; that range is inert unless `-Readback fast` or
`-Readback full` is also supplied.

The launcher exposes every experiment as a switch so a run is reproducible from
one command line, and prints a run manifest of the overrides it used:
`-Readback`, `-ReadbackRange`, `-SyncPerFrame`, `-FramesInFlight`,
`-Sharpening`, `-RtPath`, `-GammaAsUnorm16`, `-LogResolves`,
`-LogUnscaledTextures`, `-LogLevel`, `-Quiet`, and arbitrary cvars through
`-Cvar name=value`.

**Always use `-Quiet` for measured runs.** Xenia's stdout logging is
synchronous, and the game emits per-file I/O lines during play.

### Game patches

`fable2/patches/` carries the community patch bundle (600p, intro skip, 60 FPS,
High Tick Rate, Disable Texture Morphing, Disable MSAA, and content unlocks).
`fable2/patch-preset.ps1` toggles the render-config patches by name for
bisecting. `-Fps60 on|off` and `-HighTick on|off` independently control those
timing patches for evidence-gated frame-pacing tests.

**`Disable Texture Morphing` is load-bearing** — it is what fixes the black hero
and dog textures. Readback does not, at any setting. Keep it enabled.

---

## Open questions

Ranked by expected value to anyone continuing this.

1. **Does blocking persistent-pipeline initialization remove the periodic
   stutter?** The implementation is complete, but the preserved trace-enabled,
   clean non-blocking, and clean blocking boundaries still need alternating
   warmed UAT. Use WPR to choose a fallback only if blocking misses the stated
   acceptance threshold.

2. **Is `gpu_frames_in_flight = 1` useful elsewhere?** Untested. If waiting for the
   previous frame buys the same correctness as a full idle, it should recover a
   few FPS in titles that still need the synchronization workaround. Fable II
   no longer needs it after the EDRAM merge.

3. **The post-merge ROV regression is still unexplained.** ROV removed the dog
   extrusion before `437a7280c`; afterward it reintroduces the foliage halo and
   no longer removes the extrusion. This is separate from the D3D12 RTV
   workaround and may be worth reporting upstream.

4. **The morph textures.** Still black without the `Disable Texture Morphing`
   patch, and readback is definitively not the answer. Nobody has yet found what
   the real mechanism is. The patch also leaves makeup bugged, so a real fix has
   user-visible value.

5. **Other performance levers remain evidence-gated.** Logging flushes,
   asynchronous PSO creation, ISO page faults, guest pacing, shared-memory
   reuploads, and XMA each have a one-axis diagnostic in the UAT record. Do not
   combine them or promote one without a matching WPR correlation.

---

## Credits

- [Xenia](https://github.com/xenia-project/xenia) and
  [Xenia Canary](https://github.com/xenia-canary/xenia-canary) — everything
  underneath this.
- [just-harry's unofficial femtofork for Fable II](https://github.com/just-harry/unofficial-xenia-femtofork-for-fable-ii)
  — the original selective-readback idea. It does not apply to current Canary,
  but investigating why produced everything above.
- Guy, Margen67 and Just Harry for the Fable II game patches.

Licensed under the BSD license, as upstream. See [LICENSE](LICENSE).
