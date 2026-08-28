# Xenia Canary — Fable II custom build

This branch adds Fable II profiles, patches, launcher scripts, and a targeted
D3D12 workaround to a Xenia Canary base. Testing has focused on Fable II
GOTY/Platinum, title ID `4D5307F1`.

The original Canary overview is preserved in
[README-xenia-canary.md](README-xenia-canary.md). General build requirements are
documented in [docs/building.md](docs/building.md).

## Current status

| Area | Current handling | Evidence level |
|---|---|---|
| Black hero and dog textures | In reported tests, the black textures were present before the current patch set was applied and absent afterward. The bundle enables `Disable Texture Morphing` as the current workaround. | Observed in the tested configuration |
| Foliage halo and coloured lighting | The artifact was not reproduced in post-merge testing after upstream commit `437a7280c`, which changed EDRAM sample addressing. The profiles no longer force a GPU wait every frame. | Post-merge observation; cause not independently isolated |
| Dog mesh extrusion | `fable2_dog_mesh_fix` skips the matching D3D12 draw for this title and shader hash. Fix-off reproduced the extrusion and fix-on removed it in Modes A and B. | Initial A/B smoke test |
| Periodic frame-rate dips | Both profiles complete persistent pipeline-cache initialization before guest launch. | Preliminary Mode B testing favours blocking startup; formal frame-time UAT remains open |

## Test scope

- Windows and D3D12.
- Fable II GOTY/Platinum (`4D5307F1`).
- NVIDIA GTX 1660 Ti test system.

The dog-mesh workaround is D3D12-only. Vulkan has not received equivalent
Fable II validation.

## Build and run

From the repository root:

```powershell
.\xb.ps1 build --config=release `
  --cmake-define XENIA_BUILD_MISC=OFF --target xenia-app

# Quality-oriented test mode
.\fable2\run.ps1 -Mode A -Quiet "<path-to-fable-ii.iso>"

# Performance-oriented test mode
.\fable2\run.ps1 -Mode B -Quiet "<path-to-fable-ii.iso>"
```

The launcher also accepts a path to `default.xex`. It uses `fable2/` as an
isolated storage root; back up an existing save before copying it into that
directory.

`-Quiet` suppresses stdout output to reduce logging overhead and keep measured
runs comparable.

## Test modes

All three modes use the selective profile, enable the included game patches,
force VSync on, and set `framerate_limit=0`.

| Mode | Rendering | Intended use |
|---|---|---|
| A | 2× resolution with CAS | Image-quality comparison |
| B | 1× resolution with FSR | Performance comparison |
| C | Mode A plus a readback-range preset | Readback diagnostics |

Mode C behaves like Mode A while `readback_resolve="none"`. Its range becomes
active only when `-Readback fast` or `-Readback full` is supplied.

See [fable2/README.md](fable2/README.md) for launcher switches and standalone
profile details.

## Current settings and patches

Both Fable profiles currently enable:

- `fable2_dog_mesh_fix=true`;
- `shader_storage_initialization_blocking=true`;
- synchronous shader compilation (`async_shader_compilation=false`).

They leave `readback_resolve="none"` and
`await_gpu_completion_per_frame=false`. Those earlier synchronization
experiments are not part of the current Fable II configuration.

The included GOTY/Platinum [patch bundle](fable2/patches/) currently enables the
600p, 60 FPS, High Tick Rate, Disable Texture Morphing, and Disable MSAA patches,
plus the bundled intro and content patches. Inspect the exact state with:

```powershell
.\fable2\patch-preset.ps1 -Show
```

`Disable Texture Morphing` is the current workaround for black hero and dog
textures in the tested configuration. The preset script can toggle it, 600p,
MSAA, 60 FPS, and High Tick Rate for controlled comparisons.

## Fork-specific changes

| Change | Scope | Default |
|---|---|---|
| `fable2_dog_mesh_fix` | Skips a D3D12 draw matching title `4D5307F1` and vertex shader `7C5710DEF3EE33C4` | Off globally; on in both Fable profiles |
| `shader_storage_initialization_blocking` | Optionally completes persistent shader and pipeline initialization before guest launch | Off globally; on in both Fable profiles |
| Fable launcher, profiles, patches, and capture helper | Reproducible Fable II launches and diagnostics | Stored under `fable2/` |
| Readback-range and per-frame-wait controls | Investigation tools retained for explicit tests | Resolve readback is `none`; the explicit per-frame GPU wait is off in both Fable profiles |

The launcher accepts command-line cvar overrides, so either active workaround
can be compared without editing the public profiles:

```powershell
# Dog workaround control
.\fable2\run.ps1 -Mode B -Cvar fable2_dog_mesh_fix=false `
  -Quiet "<path-to-fable-ii.iso>"

# Background pipeline-initialization control
.\fable2\run.ps1 -Mode B `
  -Cvar shader_storage_initialization_blocking=false `
  -Quiet "<path-to-fable-ii.iso>"
```

Change one setting at a time when diagnosing a regression.

## Observed performance

In the latest subjective Mode B comparison on the GTX 1660 Ti system, both
clean Release configurations ran at roughly 35–50 FPS. Blocking pipeline
initialization felt slightly smoother, while the non-blocking run dipped into
the 20s more often.

These are directional observations, not benchmark results. Pass duration,
frame-time data, hitch count, median FPS, and 1% lows were not recorded. Mode A
uses the preferred 2× image quality but is substantially more GPU-intensive.

## Known limitations

- The 60 FPS patch changes the target; it does not guarantee 60 FPS.
- Hero and dog appearance currently relies on the texture-morphing game patch,
  not an emulator-side morphing fix.
- The dog workaround is limited to D3D12 and the tested title/shader pair.
- Blocking startup can increase load time, and its frame-time benefit still needs
  controlled validation.
- Performance varies with scene, mode, temperature, GPU clock, and host
  hardware.

## Documentation

- [Fable II profile and launcher](fable2/README.md): launcher switches,
  profiles, patch controls, and test procedure.
- [Fable II UAT record](fable2/UAT_RESULTS.md): dated observations, historical
  experiments, rejected hypotheses, and remaining acceptance checks.
- [Upstream Canary README](README-xenia-canary.md): general emulator usage.
- [Build instructions](docs/building.md): toolchain and dependency setup.

## Credits

- [Xenia](https://github.com/xenia-project/xenia) and
  [Xenia Canary](https://github.com/xenia-canary/xenia-canary).
- [just-harry's Fable II femtofork](https://github.com/just-harry/unofficial-xenia-femtofork-for-fable-ii)
  for the earlier Fable II work.
- [GummiFableII](https://github.com/SadTransGirl/xenia-canary-GummiFableII)
  for identifying the shader draw used by the targeted dog workaround.
- Guy, Margen67, and Just Harry for the Fable II game patches.

Licensed under the BSD license. See [LICENSE](LICENSE).
