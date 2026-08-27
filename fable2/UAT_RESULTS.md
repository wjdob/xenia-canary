# Fable II UAT results

One row per measured run. Keep every other variable fixed within a comparison:
same save, same route, same camera, same output resolution, same driver
settings, and a similar starting GPU temperature.

Always warm the shader cache on the route before recording, and always launch
measured runs with `-Quiet` so stdout logging isn't in the frame-time path.

## Final state (2026-08-27)

| Config | FPS | Visuals |
|---|---|---|
| **`-Mode B`** (1x + FSR) | **~31-37** | clean except a ~2px dark wedge under the dog |
| `-Mode A` (2x + CAS) | ~19-20 | same |

Started at ~20 FPS with a constant magenta halo. The halo was fixed by merging
upstream `437a7280c`; `await_gpu_completion_per_frame` is no longer needed and
both profiles default it off.

The remaining artifact resisted every setting tried - see the ruled-out table in
the repository README. Investigation stopped there as a deliberate call: it is
cosmetic, intermittent, and the next honest step is implementing Xenia's own
trace-viewer render-target hooks.

## Conclusion (pre-merge, historical)

**Fable II needs one CPU-GPU synchronization per frame.** Without it the light
behind foliage renders magenta/blue and textures flicker; the readback data
itself is irrelevant. `await_gpu_completion_per_frame = true` provides it for
about 3-4 FPS, versus roughly halving the frame rate with
`readback_resolve = "full"`.

Both profiles now ship `await_gpu_completion_per_frame = true` and
`readback_resolve = "none"`, so a plain `-Mode A` or `-Mode B` is correct.

**The 30 FPS target is reachable at 1x, not at 2x.** That is a hardware limit
on the GTX 1660 Ti, not a remaining bug.

## After merging upstream 437a7280c (EDRAM single-sample addressing)

Same hardware and route, **per-frame sync turned off**:

| Config | FPS | Visuals |
|---|---|---|
| 1x + FSR, `-SyncPerFrame false` | ~31-37 | halo gone; dog flicker remains |
| 2x + CAS, `-SyncPerFrame false` | ~19-20 | halo gone (one momentary blue tree); dog flicker |

The residual fault is black striping in a downward triangle from the dog's
belly to the ground, worse when the camera moves - shadow-map acne. Fable II
renders shadow maps as 256x256 at 4x MSAA.

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

### The dog flicker: what is actually known

- Black striping in a downward triangle from the dog's belly to the ground,
  worse under camera motion. The word the user reached for was "silhouette".
- Present at 1x and 2x, with and without the per-frame sync.
- **ROV removed it** - the only setting that ever has, measured before the
  merge. Not yet retested since.
- `-ExactDepth24` makes it worse, which rules out two of the three things ROV
  forces (`depth_float24_round`, `depth_float24_convert_in_pixel_shader`).
- The third thing ROV forces is `gamma_render_target_as_unorm16 = false`, and
  that is **untested**.

Both were then run, and **both failed**:

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

### The only sensible next step is a frame capture

```powershell
.\xb.ps1 build --config=release --cmake-define XENIA_BUILD_MISC=ON
.\fable2\run.ps1 -Mode B 'C:\path\to\Fable 2 PLT.iso'
# line up a shot where the dog is visibly flickering, then press F4
```

The trace lands under `fable2/scratch/gpu/` (gitignored). Open it with
`build/bin/Windows/Release/xenia-gpu-d3d12-trace-viewer.exe` and step the frame
to find the draw that produces the black striping — which render target it
writes, in what format, and what it samples.

This should have been done far earlier. Cvar bisection identified the halo
correctly but has produced nothing on the dog flicker, and a single capture
answers questions that guessing cannot.

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

## Still worth measuring

- `-FramesInFlight 1 -SyncPerFrame false` — waits for the previous frame
  instead of a full GPU idle. Cheaper if it still fixes the rendering; may
  recover a few FPS in both modes.
- The **60 FPS patch** at ~30 FPS. It was enabled before any measurement
  existed. Now that 1x is near 30, an unlocked target may hurt frame pacing;
  compare `patch-preset.ps1` with it off on **frame-time consistency**, not
  average FPS.
- `texture_cache_memory_limit_hard = 512` — VRAM was 4.8 GB of 6 GB with
  0.2 GB spilled to shared memory.
- `async_shader_compilation = true` on a warm cache.

## Procedure

1. `.\fable2\patch-preset.ps1 -Show` — confirm the patch state, record the
   preset name.
2. Warm the shader cache with the route.
3. Alternate the two configurations being compared, A/B/A/B, at least twice
   each.
4. Record the metrics below plus anything unusual in the visual checklist.

## Visual checklist

Hero · dog · morality/purity makeup · clothing menu · cutscenes · outdoor
lighting · **the light behind tree leaves** · coloured buffers · flicker ·
object pop-in · crashes.

## Patch presets

| Preset | 600p | Disable MSAA |
|--------|------|--------------|
| P0 | on | on |
| P1 | on | off |
| P2 | off | on |
| P3 | off | off |

`-Morph on|off` toggles Disable Texture Morphing independently. Neither preset
turned out to affect the halo, so that bisect was never needed.

## Runs

| Date | Mode | Preset | Overrides | Min FPS | 1% low / frame time | GPU % | GPU °C | GPU clock | VRAM | CPU % | Visual notes |
|------|------|--------|-----------|---------|---------------------|-------|--------|-----------|------|-------|--------------|
| | | | | | | | | | | | |

Paste the `Run manifest:` line the launcher prints into **Overrides** — it is
the exact set of command-line overrides that run used.
