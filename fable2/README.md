# Fable II profile

Xenia Canary with a Fable II profile, launcher and patch bundle.

Three independent Fable II defects have different fixes:

- `Disable Texture Morphing` fixes black hero and dog textures; readback does
  not.
- Upstream commit `437a7280c` fixed the magenta foliage halo with its
  single-sample EDRAM addressing.
- The D3D12 `fable2_dog_mesh_fix` removes the dog vertex-mesh extrusion. The
  control/candidate matrix passed in both supported modes, so both profiles
  enable it while the cvar remains an immediate rollback.

The remaining performance investigation is a periodic hitch roughly every
4–5 seconds. Fable II now waits for its warmed persistent pipeline cache to
finish initializing before guest execution; see
[Periodic-stutter UAT](UAT_RESULTS.md#periodic-stutter-remediation-uat) for the
controlled validation matrix.

The old femtofork's selective-readback signature never matched this build and
was removed. The general diagnostics and synchronization controls discovered
during that investigation remain available.

See [CONTEXT_HANDOFF.md](CONTEXT_HANDOFF.md) for the full investigation.

## Build and run

```powershell
.\xb.ps1 build --config=release --force `
  --cmake-define XENIA_BUILD_MISC=OFF --target xenia-app
.\fable2\run.ps1
```

Release builds intentionally compile out Xenia's internal F4 GPU trace writer.
F12 screenshots and [RenderDoc capture](capture.ps1) remain available.

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

Both ship `await_gpu_completion_per_frame = false`, `readback_resolve =
"none"`, `fable2_dog_mesh_fix = true`, and
`shader_storage_initialization_blocking = true`. Upstream's EDRAM fix made the
old per-frame sync unnecessary. Their intended rendering difference is
sharpening: `selective` uses CAS, while `quality` uses none. They retain
separate shader-cache roots so profile experiments do not contaminate each
other.

The profile names are historical; "selective" no longer refers to anything.

```powershell
.\fable2\run.ps1 -Profile selective
```

## A/B/C UAT

These modes use the same profile and shader cache, force VSync on, and apply
the same enabled game patches:

```powershell
.\fable2\run.ps1 -Mode A "D:\Games\Fable II.iso" # 2x + CAS
.\fable2\run.ps1 -Mode B "D:\Games\Fable II.iso" # 1x + FSR  <-- recommended
.\fable2\run.ps1 -Mode C "D:\Games\Fable II.iso" # Mode A + readback-range preset
```

**`-Mode B` is the recommended configuration: roughly 30 FPS with the dog-mesh
fix enabled.** `-Mode A` runs roughly 20 FPS and preserves the preferred 2x
image quality. Mode B is 1x with FSR upscaling, so it is not a plain resolution
drop.

Mode C only sets `ReadbackRange` to `0x1B600000,0x800000`; with the default
`readback_resolve = "none"`, that range is inert and Mode C behaves like Mode A.
Supply `-Readback fast` or `-Readback full` to activate a range experiment.

Record results in [UAT_RESULTS.md](UAT_RESULTS.md). Always add `-Quiet` to
measured runs — stdout logging is synchronous and distorts frame times.

### Dog-mesh workaround result

The direct A/B controls reproduced the triangular extrusion, and enabling the
cvar removed it without a reported frame-rate regression:

```powershell
.\fable2\run.ps1 -Mode A -Cvar fable2_dog_mesh_fix=false -Quiet "D:\Games\Fable II.iso"
.\fable2\run.ps1 -Mode A -Cvar fable2_dog_mesh_fix=true  -Quiet "D:\Games\Fable II.iso"
.\fable2\run.ps1 -Mode B -Cvar fable2_dog_mesh_fix=false -Quiet "D:\Games\Fable II.iso"
.\fable2\run.ps1 -Mode B -Cvar fable2_dog_mesh_fix=true  -Quiet "D:\Games\Fable II.iso"
```

| Mode | Fix off | Fix on |
|---|---|---|
| A | extrusion present | extrusion absent, ~20 FPS |
| B | extrusion present | extrusion absent, ~30 FPS |

The first matching skip is logged. Use
`-Cvar fable2_dog_mesh_fix=false` for immediate rollback if a later scene
reveals missing dog geometry, animation, or shadow behavior.

### Periodic-stutter baseline

The build inherited a sticky `XENIA_ENABLE_TRACE_WRITER=ON` CMake cache entry.
That produced an optimized Release executable, but with F4 trace hooks compiled
into hot GPU paths. No trace was active, so this is not itself a demonstrated
4–5-second timer; clean Release builds remove the hidden variable.

The same log queued 532 cached pipeline descriptions, of which 258 still needed
shader translation, on up to seven workers while
`async_shader_compilation=false`. Previously the guest launched immediately
and the `0 ms` message measured only queueing. With
`shader_storage_initialization_blocking=true`, the loading indicator remains
active until this work completes and the log reports actual completion time.
This changes startup only; A/B/C rendering semantics remain unchanged.

For a non-blocking control on the same clean executable:

```powershell
.\fable2\run.ps1 -Mode B `
  -Cvar shader_storage_initialization_blocking=false,fable2_dog_mesh_fix=true `
  -Quiet "D:\Games\Fable II.iso"
```

Free at least 20 GB on the SSD containing the ISO before comparing builds, but
preserve saves and the warmed shader cache. The three-boundary matrix, metrics,
acceptance threshold, and evidence-gated fallbacks are in
[UAT_RESULTS.md](UAT_RESULTS.md#periodic-stutter-remediation-uat).

## Diagnostics

F12 takes Xenia screenshots normally and is the capture key used by
`capture.ps1` under RenderDoc. F4 is a different facility: Xenia's internal GPU
trace writer, available in Debug builds and intentionally compiled out of the
clean Release gameplay build.

The readback path has several early exits that used to fail silently, which is
why a game could get no readback at all with nothing in the log. They are now
reported as warnings at the default log level, rate-limited after the first
occurrence.

```powershell
# Which destinations does the game resolve to, and in what format?
.\fable2\run.ps1 -Mode A -LogResolves -Quiet "D:\Games\Fable II.iso"

# Which textures can't be read from the scaled resolve buffer at 2x?
.\fable2\run.ps1 -Mode A -LogUnscaledTextures -Quiet "D:\Games\Fable II.iso"
```

In `build/bin/Windows/Release/xenia.log`:

- `Resolve: dest 0x...` — one line per distinct resolve signature. This is the
  table to pick a `-ReadbackRange` from.
- `Resolve readback to 0x... skipped because ...` — readback was requested but
  dropped, with the failing prerequisite named.
- `log_unscaled_resolve_textures is active` — confirms that check is running, so
  that finding no reports under it actually means something.

## Experiment switches

```powershell
.\fable2\run.ps1 -Mode A -Readback fast                          # none | fast | full
.\fable2\run.ps1 -Mode C -ReadbackRange "0x1A100000,0x100000"    # narrow the readback
.\fable2\run.ps1 -Mode A -Sharpening bilinear                    # bilinear | cas | fsr
.\fable2\run.ps1 -Mode A -GammaAsUnorm16 false                   # wrong colours on bright effects
.\fable2\run.ps1 -Mode A -RtPath rov                             # accuracy oracle, slower
.\fable2\run.ps1 -Mode A -LogLevel 3                             # everything, very slow
```

`-ExactDepth24` forces the two depth-precision settings the ROV backend always
uses (`depth_float24_convert_in_pixel_shader` and `depth_float24_round`). It was
tested against the dog extrusion and made rendering worse; it is retained only
as a general diagnostic.

`-SyncPerFrame` and `-FramesInFlight` control per-frame CPU-GPU synchronization.
This was the fix before upstream's EDRAM rework; since that merge it fixes
nothing here and only costs frame rate, so both profiles default it off.

`-Readback` and `-ReadbackRange` are no longer needed for this title. They
remain useful for other titles: the cost of readback scales with the *number*
of resolves read back rather than their size, which is what `-ReadbackRange`
exploits. A range alone does nothing while readback is `none`.

Overrides are applied after the mode defaults, and Xenia's parser takes the last
occurrence of a flag, so `-Mode B -Sharpening bilinear` does override Mode B's
FSR.

`-ScaleThreshold` also exists, but **do not use it with Fable II**. Mixing 2x
and native render targets breaks this game's heavy EDRAM aliasing: at 640 the
whole scene blows out to white, blue and magenta. It is faster, and completely
unusable.

`rov` is the pixel-shader-interlock render backend. Before the EDRAM merge it
removed the dog artifact; afterward it reintroduces the halo and no longer
removes the extrusion. It is too slow to ship and is not an accuracy oracle for
this symptom.

## Patches

The active bundle is in [patches/](patches/). Inspect and toggle it with:

```powershell
.\fable2\patch-preset.ps1 -Show
.\fable2\patch-preset.ps1 -Preset P2
.\fable2\patch-preset.ps1 -Morph on
.\fable2\patch-preset.ps1 -Fps60 off -HighTick on
```

Currently enabled: 600p Resolution, Skip intro videos (twice — redundant but
intentional), 60 FPS, High Tick Rate, Unlock Website Items, Disable Texture
Morphing, Disable MSAA, Unlock Collectors Edition Content.

`Disable Texture Morphing` is what fixes the black hero and dog textures. The
selective readback signature never matched, and even global
`readback_resolve = "fast"` leaves the hero and dog black, so readback is not
the mechanism at all. Keep this patch enabled.

`Disable MSAA` and `600p Resolution` write 16 bytes apart in what is almost
certainly the same render-config structure, so they are not independent — that
is what the P0–P3 presets exist to bisect. Neither turned out to affect the
halo, so that bisect was never needed.

## Test order

1. Complete the three-boundary periodic-stutter matrix on Mode B's stationary
   reproduction, then validate the winner in both A and B.
2. Check the dog body, coat, legs, tail, animation and ordinary shadow, plus
   hero/dog textures, foliage halo, cutscenes and crashes.
3. Change only the fallback implicated by the WPR trace; do not combine cvar or
   patch experiments.
4. If 2x is too slow, use `-Mode B` (1x + FSR), the recommended configuration.

Keep VSync, patches, and the test location unchanged during each comparison.

Note that Xenia rewrites the profile TOML on exit — hex becomes decimal and new
cvars get appended. Command-line overrides are not written back.

`use_fuzzy_alpha_epsilon` is left off: it targets NVIDIA alpha-test flicker, not
opaque colored boxes, and can change transparency. `clear_memory_page_state` is
enabled because current Fable II reports associate it with reduced video
flicker. Synchronous shader compilation is kept on (async off) because skipped
draws while pipelines compile produce exactly the coloured buffers this profile
is trying to avoid.
