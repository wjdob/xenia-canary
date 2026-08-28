# Fable II UAT results

One row per measured run. Keep every other variable fixed within a comparison:
same save, same route, same camera, same output resolution, same driver
settings, and a similar starting GPU temperature.

Always warm the shader cache on the route before recording, and always launch
measured runs with `-Quiet` so stdout logging isn't in the frame-time path.

## Rendering state (2026-08-27)

| Config | FPS | Visuals |
|---|---|---|
| **`-Mode B`** (1x + FSR, dog fix on) | **~30** | dog extrusion absent |
| `-Mode A` (2x + CAS, dog fix on) | ~20 | dog extrusion absent |

Started at ~20 FPS with a constant magenta halo. The halo was fixed by merging
upstream `437a7280c`; `await_gpu_completion_per_frame` is no longer needed and
both profiles default it off.

The remaining dog artifact resisted every generic setting tried. Screenshots
and a matching implementation in another Fable II fork pointed to a redundant
draw using vertex shader `7C5710DEF3EE33C4`, not a render-target or shadow-map
fault. The D3D12 `fable2_dog_mesh_fix` cvar skips that draw. The direct A/B
matrix below passed, and both Fable profiles now enable the cvar.

Mode C only preselects readback range `0x1B600000,0x800000`. It is inert with
the default `readback_resolve = "none"`; use `-Readback fast` or `-Readback
full` to make Mode C an actual readback experiment.

## Completed dog-mesh workaround UAT

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
| A | dog extrusion reproduced | extrusion absent, ~20 FPS |
| B | dog extrusion reproduced | extrusion absent, ~30 FPS |

No new dog-geometry defect or performance regression was reported. The fix is
accepted and enabled in both profiles, while
`-Cvar fable2_dog_mesh_fix=false` remains the rollback.

## Periodic-stutter remediation UAT

### Why this boundary is being tested

At `7a3564620998264c07270dd309427fbfba017259`, local `HEAD` and
`origin/fable2-custom` were identical; the stutter was therefore not explained
by an unpushed Claude source delta. The local build directory did retain a
hidden `XENIA_ENABLE_TRACE_WRITER=ON` CMake cache value. The resulting
executable was optimized Release, but F4 trace hooks were compiled into hot GPU
paths even though no trace was active.

The same run queued 532 persistent pipeline descriptions, with 258 shader
translations still required, on up to seven workers. The guest launched while
that work ran in the background despite the Fable profiles setting
`async_shader_compilation=false`. The old `0 ms` log measured queueing rather
than completion. `shader_storage_initialization_blocking=true` now holds the
initialization indicator and guest launch until the cache work completes, and
logs the actual completion time.

F4 and F12 are unrelated: F4 writes Xenia's internal GPU trace and is now
compiled out of Release; F12 still takes ordinary screenshots and triggers a
RenderDoc capture when launched through `capture.ps1`.

### Preconditions

- Free at least 20 GB on `C:` before measuring. Preserve the ISO, saves, and
  warmed shader cache.
- Use the same save, fixed camera, stationary location, route, output
  resolution, patches, driver settings, and similar starting temperature.
- Keep `fable2_dog_mesh_fix=true`, 60 FPS, High Tick Rate, and every other game
  patch unchanged throughout the primary matrix.
- Preserve the trace-enabled/non-blocking control executable as
  `build/controls/xenia_canary_trace_on_nonblocking_A45899D9.exe`. Its SHA-256
  is `A45899D9780303426C7C8C2F171AC4BC0BACE0DD94C7181DA987A0B3881EA508`.

### Three-boundary matrix

| Boundary | Trace hooks | Pipeline startup | Purpose |
|---|---|---|---|
| 1. Preserved control | compiled in, inactive | background | Reproduce the original build state. |
| 2. Clean Release control | compiled out | background | Isolate the sticky trace-build delta. |
| 3. Candidate | compiled out | blocking | Isolate pipeline work overlapping gameplay. |

Launch the preserved boundary directly so the normal runner can continue to
target the new Release executable:

```powershell
$fableControlExe = (Resolve-Path ".\build\controls\xenia_canary_trace_on_nonblocking_A45899D9.exe").Path
$fableConfig = (Resolve-Path ".\fable2\fable2-2x-selective.config.toml").Path
$fableStorage = (Resolve-Path ".\fable2").Path
& $fableControlExe `
  "--storage_root=$fableStorage" "--config=$fableConfig" `
  --apply_patches=true --vsync=true --framerate_limit=0 `
  --draw_resolution_scale_x=1 --draw_resolution_scale_y=1 `
  --postprocess_scaling_and_sharpening=fsr `
  --fable2_dog_mesh_fix=true --log_to_stdout=false `
  "D:\Games\Fable II.iso"
```

Use the same newly built executable for boundaries 2 and 3:

```powershell
# Boundary 2: clean Release, current Canary background behavior
.\fable2\run.ps1 -Mode B `
  -Cvar shader_storage_initialization_blocking=false,fable2_dog_mesh_fix=true `
  -Quiet "D:\Games\Fable II.iso"

# Boundary 3: clean Release, wait for persistent pipeline initialization
.\fable2\run.ps1 -Mode B `
  -Cvar shader_storage_initialization_blocking=true,fable2_dog_mesh_fix=true `
  -Quiet "D:\Games\Fable II.iso"
```

Boundary 3 must log `Shader storage initialization started in blocking mode`
and `Shader storage initialization completed in N milliseconds (blocking
mode)` before guest launch. Boundary 2 uses the same messages with `background`
and explicitly reports that queued pipeline compilation continues.

### Preliminary UAT observation (2026-08-27)

Using the two Mode B commands above, blocking initialization felt slightly
smoother and ran at roughly 35–50 FPS. The clean non-blocking run had a broadly
similar range, but dipped into the 20s more often. No new regression was
reported, so blocking remains enabled in both Fable profiles.

This is directional evidence, not formal acceptance. Pass duration, preload
time, frame-time data, hitch cadence/count, median and 1% low FPS, utilization,
clock, and temperature were not recorded. The alternating warmed passes and
acceptance checks below therefore remain open.

Give each executable one untimed warm-up. Start with Mode B's fixed-camera
stationary reproduction, then validate the winning configuration in A and B.
Alternate configurations and record two warmed 10-minute passes per mode.

Record startup preload duration, minimum/median/1% low FPS, hitches per minute,
CPU and GPU utilization, GPU temperature and core clock. Define a hitch as a
present interval greater than twice its local rolling median. WPR is diagnostic
evidence rather than a performance run: capture one 60–90-second
CPU/GPU/File-I/O trace for clean non-blocking and blocking runs, writing ETLs
to `D:` so trace output does not contend with the ISO.

From an elevated PowerShell prompt:

```powershell
New-Item -ItemType Directory -Force "D:\Fable2-WPR-Temp" | Out-Null
wpr -start CPU.light -start GPU.light -start DiskIO.light `
  -start FileIO.light -start Thermal.light -filemode `
  -recordtempto "D:\Fable2-WPR-Temp"
# Reproduce for 60–90 seconds, then:
wpr -stop "D:\Fable2-stutter.etl"
```

Accept blocking startup only when:

- Pipeline completion is logged before the guest main thread starts.
- The recurring 3.5–5.5-second cadence is absent in every blocking pass.
- Hitches per minute fall by at least 80%.
- Median and 1% low performance regress by no more than 3%.
- Dog geometry, hero/dog textures, foliage, coloured buffers, audio, cutscenes,
  and stability remain correct.

### Evidence-gated fallback

Change only the candidate associated with the WPR activity at each hitch:

| Correlated work | Next isolated test |
|---|---|
| Log writer or filesystem flush | `flush_log=false`, then `log_level=1` only if needed. |
| Runtime shader/PSO creation | `async_shader_compilation=true` with two creation threads; reject skipped or coloured draws. |
| ISO reads or hard page faults | Test a fresh copy on the SSD after freeing space; do not use the slower `D:` HDD as the primary fix. |
| Guest frame limiter without I/O | Compare `vsync=true, framerate_limit=0` with `vsync=false, framerate_limit=60`; then test only the 60 FPS patch off while retaining High Tick Rate. |
| Shared-memory reuploads | `clear_memory_page_state=false`, with the full visual checklist. |
| XMA/audio stacks | Diagnose with `apu=nop`, then `xma_decoder=old`; require normal audio before promotion. |

If WPR is inconclusive, compare the clean sibling Canary build at `1e834f8a8`
and bisect the pre-capture and upstream-merge boundaries in isolated worktrees.
Only then add logging for pipeline creation, GPU waits, texture eviction, and
VFS reads exceeding 8–10 ms, with `flush_log=false`.

## Conclusion (pre-merge, historical)

**Fable II needs one CPU-GPU synchronization per frame.** Without it the light
behind foliage renders magenta/blue and textures flicker; the readback data
itself is irrelevant. `await_gpu_completion_per_frame = true` provides it for
about 3-4 FPS, versus roughly halving the frame rate with
`readback_resolve = "full"`.

At that point both profiles shipped `await_gpu_completion_per_frame = true` and
`readback_resolve = "none"`. This is a historical result: after the EDRAM merge
the profiles changed the sync back to `false`.

**The 30 FPS target is reachable at 1x, not at 2x.** That is a hardware limit
on the GTX 1660 Ti, not a remaining bug.

## After merging upstream 437a7280c (EDRAM single-sample addressing)

Same hardware and route, **per-frame sync turned off**:

| Config | FPS | Visuals |
|---|---|---|
| 1x + FSR, `-SyncPerFrame false` | ~31-37 | halo gone; dog flicker remains |
| 2x + CAS, `-SyncPerFrame false` | ~19-20 | halo gone (one momentary blue tree); dog flicker |

The residual fault appeared as a dark triangle from the dog's belly to the
ground, worse when the camera moved. It was initially classified as shadow-map
acne because Fable II renders 256x256 shadow maps at 4x MSAA; later evidence
superseded that classification with a vertex-mesh extrusion.

Both follow-ups have now been run:

| Run | Result |
|---|---|
| `-Mode B` (sync **on**) | Only the dog flicker remains - same as sync off - but choppier. **The sync no longer earns its cost.** |
| `-Mode B -SyncPerFrame false -ExactDepth24` | **Worse.** Widespread texture flicker, the dog triangle, and foliage showing through solid objects as silhouettes. |

So `await_gpu_completion_per_frame` is now `false` in both profiles: after the
upstream merge it fixes nothing here and only costs frame rate. Keep the cvar -
it is general, and it was genuinely the fix before the merge.

`-ExactDepth24` is a **dead end** for this title. Forcing exact 20e4 depth makes
rendering distinctly worse rather than better, which also means the shadow-acne
reading of the dog flicker is not supported. Worth noting that
`depth_float24_convert_in_pixel_shader` interacting badly with the new EDRAM
sample addressing would be an upstream bug in its own right.

### The dog flicker: historical cvar investigation

- A narrow triangle extruded from the dog's mesh toward the ground, worse under
  camera motion. It was originally described as black striping or a silhouette.
- Present at 1x and 2x, with and without the per-frame sync.
- Before the post-merge follow-up, **ROV was the only setting that had removed
  it**, measured on the earlier tree.
- `-ExactDepth24` makes it worse, which rules out two of the three things ROV
  forces (`depth_float24_round`, `depth_float24_convert_in_pixel_shader`).
- The third thing ROV forces is `gamma_render_target_as_unorm16 = false`, and
  that remained untested at this stage.

The post-merge ROV and gamma runs were then performed, and **both failed**:

| Run | FPS | Result |
|---|---|---|
| `-Mode B -RtPath rov` | heavy stutter | **Halo is back**, dog still flickers |
| `-Mode B -Cvar gamma_render_target_as_unorm16=false` | 28-41 | halo gone, dog still flickers |

The ROV result is the significant one. **Before the upstream merge, ROV was the
only setting that removed the dog flicker, and it left the halo alone. After the
merge it does neither — it reintroduces the halo and still flickers.** Upstream
`437a7280c` evidently improved the RTV path and regressed the ROV path. That is
a clean, reproducible observation and is worth reporting upstream on its own
merits, independent of Fable II.

Consequences here: all three settings ROV forces are now ruled out
(`depth_float24_round` and `depth_float24_convert_in_pixel_shader` via
`-ExactDepth24`, which made things worse; `gamma_render_target_as_unorm16` on
its own, which changed nothing), and ROV itself is no longer a reference for
correct behaviour. **The cvar-guessing avenue is exhausted.**

### Superseded next-step hypothesis: trace-viewer render targets

```powershell
.\xb.ps1 build --config=debug --force `
  --cmake-define XENIA_BUILD_MISC=ON `
  --target xenia-gpu-d3d12-trace-viewer --target xenia-app
.\fable2\run.ps1 -Mode B "D:\Games\Fable II.iso"
# line up a shot where the dog is visibly flickering, then press F4
```

F4 internal tracing is Debug-only; it is intentionally absent from Release.
The trace lands under `fable2/scratch/gpu/` (gitignored). This was previously
recorded as the next step on the assumption that the dog artifact came from a
shadow or render-target pass. That hypothesis is now superseded: screenshots
show a vertex-mesh extrusion, and vertex shader `7C5710DEF3EE33C4` matches the
known redundant draw skipped by another Fable II fork. The targeted workaround
has since passed the A/B matrix.

## Measured (before the upstream merge)

GTX 1660 Ti laptop, i5-9300H, same outdoor route, patch preset P0.

| Config | FPS | Visuals |
|---|---|---|
| **`-Mode B`** (1x + FSR, per-frame sync) | **~26-30** | **clean** |
| `-Mode A` (2x + CAS, per-frame sync) | ~16-17 | clean |
| 2x, `-Readback full` | ~10 | clean |
| 2x, `-Readback fast` | ~17 | halo + flicker |
| 2x, `readback none`, no sync | ~20 | halo + flicker |
| 1x, `-Readback full` | ~13 | clean |
| 1x, `readback none`, no sync | ~31 | halo + flicker |
| 2x, `-ScaleThreshold 640` | fast | **unusable** — whole scene blows out |

Readback range bisect at 2x, all with `readback full` limited to one region —
this is what showed the cost is per-stall and the data is irrelevant:

| `-ReadbackRange` | Resolve dests in range | FPS | Visuals |
|---|---|---|---|
| `0x1B600000,0x800000` | 5, all load-time only | ~19-20 | halo + flicker |
| `0x1ED00000,0x100000` | 1 | ~17-18 | clean |
| `0x1A100000,0x100000` | 3 | ~17-18 | clean |
| `0x19E00000,0x400000` | 5 | ~13-14 | clean |
| `0x12A00000,0x400000` | 15 | ~12-13 | clean |
| `0x12700000,0x300000` | ~80 | ~12-13 | clean |

## Other historical performance ideas

- `-FramesInFlight 1 -SyncPerFrame false` — waits for the previous frame
  instead of a full GPU idle. Cheaper if it still fixes the rendering; may
  recover a few FPS in both modes.
- `texture_cache_memory_limit_hard = 512` — VRAM was 4.8 GB of 6 GB with
  0.2 GB spilled to shared memory.

The 60 FPS patch and asynchronous shader compilation now belong to the
evidence-gated stutter matrix above, not the first round of experiments.

## Procedure

1. `.\fable2\patch-preset.ps1 -Show` — confirm the patch state, record the
   preset name.
2. Warm the shader cache with the route.
3. Alternate the two configurations being compared, A/B/A/B, at least twice
   each.
4. Record the metrics below plus anything unusual in the visual checklist.

## Visual checklist

Hero · dog body/coat/legs/tail/animation/shadow · dog-mesh extrusion ·
morality/purity makeup · clothing menu · cutscenes · outdoor lighting · **the
light behind tree leaves** · coloured buffers · flicker · object pop-in ·
crashes.

## Patch presets

| Preset | 600p | Disable MSAA |
|--------|------|--------------|
| P0 | on | on |
| P1 | on | off |
| P2 | off | on |
| P3 | off | off |

`-Morph on|off`, `-Fps60 on|off`, and `-HighTick on|off` toggle those patches
independently. Neither render preset affected the halo, so that bisect was
never needed. Leave 60 FPS and High Tick Rate on during the primary stutter
matrix; their switches exist for the frame-limiter fallback only.

## Runs

| Date | Boundary / mode | Overrides | Preload | Median / min / 1% low FPS | Hitches/min | CPU % | GPU % / °C / clock | Visual notes |
|------|-----------------|-----------|---------|----------------------------|--------------|-------|---------------------|--------------|
| | | | | | | | | |

Paste the `Run manifest:` line the launcher prints into **Overrides** — it is
the exact set of command-line overrides that run used.
