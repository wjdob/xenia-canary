# Fable II profile

Xenia Canary with a Fable II profile, launcher and patch bundle.

Reported tests currently support these separate workarounds:

- Black hero and dog textures were reported before the current patch set and
  absent afterward. `Disable Texture Morphing` is the current workaround. The
  old selective-readback signature did not activate in the recorded tests, and
  the tested global fast-readback setting did not remove them.
- The magenta foliage halo was not reproduced after merging upstream commit
  `437a7280c`, which changed EDRAM sample addressing.
- In initial D3D12 A/B checks, enabling `fable2_dog_mesh_fix` removed the
  reported dog-mesh extrusion. Both profiles enable it, and the cvar remains
  available for rollback.

A periodic hitch roughly every 4–5 seconds has also been reported. Both
profiles now wait for warmed persistent-pipeline initialization before guest
execution. Preliminary testing favours this setting, but controlled validation
remains open; see
[Periodic-stutter UAT](UAT_RESULTS.md#periodic-stutter-remediation-uat) for the
controlled validation matrix.

The detailed test record and investigation history are in
[UAT_RESULTS.md](UAT_RESULTS.md).

## Build and run

```powershell
.\xb.ps1 build --config=release `
  --cmake-define XENIA_BUILD_MISC=OFF --target xenia-app
.\fable2\run.ps1
```

Release builds intentionally compile out Xenia's internal F4 GPU trace writer.
F12 screenshots and [RenderDoc capture](capture.ps1) remain available.

A clean Windows build also needs the Vulkan shader tools described in the
[build instructions](../docs/building.md), even when the runtime profile uses
D3D12.

Pass an ISO or `default.xex` path to launch it directly:

```powershell
.\fable2\run.ps1 "<path-to-default.xex>"
```

The runner uses `fable2` as an isolated storage root. Copy an existing Fable II
save into `fable2/content` only after backing it up.

## Profiles

Both ship `await_gpu_completion_per_frame = false`,
`readback_resolve = "none"`, `fable2_dog_mesh_fix = true`, and
`shader_storage_initialization_blocking = true`. The old per-frame sync was no
longer needed in the recorded post-merge tests.

The most relevant rendering difference is sharpening: `selective` explicitly
uses CAS, while `quality` leaves post-processing at its default. The TOML files
also contain diagnostic and incidental differences, so they are not a clean
one-variable comparison. Separate cache roots keep their shader caches
isolated; use Modes A/B/C for controlled rendering comparisons.

The `selective` name is historical and comes from the removed selective-readback
experiment.

```powershell
.\fable2\run.ps1 -Profile selective
```

## A/B/C UAT

These modes use the same profile and shader cache, force VSync on, and apply
the same enabled game patches:

```powershell
.\fable2\run.ps1 -Mode A "<path-to-fable-ii.iso>" # 2x + CAS
.\fable2\run.ps1 -Mode B "<path-to-fable-ii.iso>" # 1x + FSR performance comparison
.\fable2\run.ps1 -Mode C "<path-to-fable-ii.iso>" # Mode A + readback-range preset
```

Mode A is the 2× image-quality option. Mode B renders at 1× with FSR and has
generally run faster in the reported tests. Frame rates vary by build, scene,
and test route; see [UAT_RESULTS.md](UAT_RESULTS.md) for dated observations.

Mode C only sets `ReadbackRange` to `0x1B600000,0x800000`; with the default
`readback_resolve = "none"`, that range is inert and Mode C behaves like Mode A.
Supply `-Readback fast` or `-Readback full` to activate a range experiment.

Record results in [UAT_RESULTS.md](UAT_RESULTS.md). Add `-Quiet` to measured
runs to suppress stdout output and keep comparisons consistent.

### Workaround controls

Both profiles enable the dog draw workaround. The initial A/B checks reproduced
the extrusion with the cvar off and did not reproduce it with the cvar on. Use
this rollback to investigate a later dog geometry or animation regression:

```powershell
.\fable2\run.ps1 -Mode B -Cvar fable2_dog_mesh_fix=false `
  -Quiet "<path-to-fable-ii.iso>"
```

Both profiles also wait for persistent pipeline initialization before guest
launch. A preliminary Mode B comparison favoured blocking startup, but the
timed frame-time acceptance matrix remains open. Compare background startup
with:

```powershell
.\fable2\run.ps1 -Mode B `
  -Cvar shader_storage_initialization_blocking=false `
  -Quiet "<path-to-fable-ii.iso>"
```

See the [dog workaround results](UAT_RESULTS.md#completed-dog-mesh-workaround-uat)
and [periodic-stutter UAT](UAT_RESULTS.md#periodic-stutter-remediation-uat) for
the recorded observations and acceptance criteria.

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
.\fable2\run.ps1 -Mode A -LogResolves -Quiet "<path-to-fable-ii.iso>"

# Which textures can't be read from the scaled resolve buffer at 2x?
.\fable2\run.ps1 -Mode A -LogUnscaledTextures -Quiet "<path-to-fable-ii.iso>"
```

In `build/bin/Windows/Release/xenia.log`:

- `Resolve: dest 0x...` — one line per distinct resolve signature. This is the
  table to pick a `-ReadbackRange` from.
- `Resolve readback to 0x... skipped because ...` — readback was requested but
  dropped, with the failing prerequisite named.
- `log_unscaled_resolve_textures is active` — confirms that the diagnostic is
  active; no further entries means no matching textures were observed.

## Experiment switches

```powershell
.\fable2\run.ps1 -Mode A -Readback fast                          # none | fast | full
.\fable2\run.ps1 -Mode C -Readback full `
  -ReadbackRange "0x1A100000,0x100000"                           # activate one range
.\fable2\run.ps1 -Mode A -Sharpening bilinear                    # bilinear | cas | fsr
.\fable2\run.ps1 -Mode A -GammaAsUnorm16 false                   # gamma render-target diagnostic
.\fable2\run.ps1 -Mode A -RtPath rov                             # diagnostic only; slow and regressed here
.\fable2\run.ps1 -Mode A -LogLevel 3                             # everything, very slow
```

`-ExactDepth24` forces the two depth-precision settings the ROV backend always
uses (`depth_float24_convert_in_pixel_shader` and `depth_float24_round`). It was
tested against the dog extrusion and made rendering worse; it is retained only
as a general diagnostic.

`-SyncPerFrame` and `-FramesInFlight` control per-frame CPU-GPU synchronization.
The sync workaround was used before upstream's EDRAM rework; it was no longer
needed in the recorded post-merge tests, so both profiles default it off.

`-Readback` and `-ReadbackRange` are not enabled by the current profiles. They
remain available for explicit diagnostics; a range alone does nothing while
readback is `none`.

Overrides are applied after the mode defaults, and Xenia's parser takes the last
occurrence of a flag, so `-Mode B -Sharpening bilinear` does override Mode B's
FSR.

`-ScaleThreshold` is retained for diagnostics. In the recorded Fable II test
at 640, it caused severe white, blue, and magenta corruption. The exact cause
was not established, so it is not recommended for normal play.

`rov` is the pixel-shader-interlock render backend. Before the EDRAM merge it
removed the dog artifact; afterward it reintroduces the halo and no longer
removes the extrusion in the recorded tests. It performed poorly there and is
not used by the supplied modes.

## Patches

The active bundle is in [patches/](patches/). Inspect and toggle it with:

```powershell
.\fable2\patch-preset.ps1 -Show
.\fable2\patch-preset.ps1 -Preset P2
.\fable2\patch-preset.ps1 -Morph on
.\fable2\patch-preset.ps1 -Fps60 off -HighTick on
```

Currently enabled: 600p Resolution, two entries named Skip intro videos, 60 FPS,
High Tick Rate, Unlock Website Items, Disable Texture Morphing, Disable MSAA,
and Unlock Collectors Edition Content.

Black hero and dog textures were reported before the current patch set and
absent afterward. `Disable Texture Morphing` is the current workaround. The old
selective-readback signature did not activate in the recorded tests, and global
`readback_resolve = "fast"` did not remove the black textures. Keep the patch
enabled unless testing that behavior explicitly.

`Disable MSAA` and `600p Resolution` write 16 bytes apart, but their relationship
and individual visual effects have not been isolated.

## Test order

1. Complete the three-boundary periodic-stutter matrix on Mode B's stationary
   reproduction, then validate the winner in both A and B.
2. Check the dog body, coat, legs, tail, animation and ordinary shadow, plus
   hero/dog textures, foliage halo, cutscenes and crashes.
3. If a WPR trace correlates a fallback subsystem with the hitch, test only
   that fallback; do not combine cvar or patch experiments.
4. If 2× is too slow in the current scene, compare it with `-Mode B` (1× + FSR).

Keep VSync, patches, and the test location unchanged during each comparison.

Note that Xenia rewrites the profile TOML on exit — hex becomes decimal and new
cvars get appended. Command-line overrides are not written back.

`use_fuzzy_alpha_epsilon` remains off because this investigation did not
establish it as relevant to the reported artifacts. `clear_memory_page_state`
remains enabled and asynchronous shader compilation remains off; neither
setting has been isolated in the current UAT.
