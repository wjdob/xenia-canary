# Fable II profile

Xenia Canary with a Fable II profile, launcher and patch bundle.

**What Fable II actually needs is one CPU-GPU synchronization per frame.**
Without it the light behind foliage renders magenta and textures flicker. Both
profiles ship `await_gpu_completion_per_frame = true`, which costs about 3-4 FPS.

The old femtofork's selective-readback idea was ported, tested, and removed: its
signature never matched this build, and readback does not fix the morph
textures — `readback_resolve = "full"` looked like a fix only because of the
stall it happened to cause, at roughly half the frame rate. The investigation's
general leftovers stayed in: resolve logging, readback skip reporting,
submission fences on the readback buffers, a readback destination range filter,
and the per-frame sync itself.

See [CONTEXT_HANDOFF.md](CONTEXT_HANDOFF.md) for the full investigation.

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

Both ship `await_gpu_completion_per_frame = true` with `readback_resolve =
"none"`. That per-frame CPU-GPU sync is what Fable II actually needs to render
correctly — without it the light behind foliage goes magenta and textures
flicker. They differ only in sharpening: `selective` uses CAS, `quality` uses
none.

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
.\fable2\run.ps1 -Mode C "D:\Games\Fable II.iso" # 2x + CAS, readback-range experiments
```

**`-Mode B` is the recommended configuration: ~26-30 FPS, clean.** `-Mode A` is
also clean but runs ~16-17 FPS — 2x cannot reach 30 on a GTX 1660 Ti, which is
a hardware limit rather than a remaining bug. Mode B is 1x with FSR upscaling,
so it is not a plain resolution drop.

Mode C exists only for readback-range experiments and is no longer needed.

Record results in [UAT_RESULTS.md](UAT_RESULTS.md). Always add `-Quiet` to
measured runs — stdout logging is synchronous and distorts frame times.

## Diagnostics

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
uses (`depth_float24_convert_in_pixel_shader` and `depth_float24_round`).
Shadow-map striping is a depth-precision artifact, so it is the first thing to
try for the residual dog flicker on the RTV path.

`-SyncPerFrame` and `-FramesInFlight` control the per-frame synchronization the
game needs; both profiles already enable it, so these are only for testing.
`-FramesInFlight 1 -SyncPerFrame false` is the cheaper variant worth trying —
it waits for the previous frame instead of a full GPU idle.

`-Readback` and `-ReadbackRange` are no longer needed for this title — readback
is off and the per-frame sync does the job. They remain useful for other
titles: the cost of readback scales with the *number* of resolves read back
rather than their size, which is what `-ReadbackRange` exploits.

Overrides are applied after the mode defaults, and Xenia's parser takes the last
occurrence of a flag, so `-Mode B -Sharpening bilinear` does override Mode B's
FSR.

`-ScaleThreshold` also exists, but **do not use it with Fable II**. Mixing 2x
and native render targets breaks this game's heavy EDRAM aliasing: at 640 the
whole scene blows out to white, blue and magenta. It is faster, and completely
unusable.

`rov` is the pixel-shader-interlock render backend. It removes the texture
flicker but not the halo, and is far too slow to ship — useful only as an
accuracy oracle.

## Patches

The active bundle is in [patches/](patches/). Inspect and toggle it with:

```powershell
.\fable2\patch-preset.ps1 -Show
.\fable2\patch-preset.ps1 -Preset P2
.\fable2\patch-preset.ps1 -Morph on
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

1. Start with `-Mode A`. Check the opening, first outdoor area, hero
   adulthood/makeup, dog appearance, and the clothing menu.
2. For wrong-colour effects or flicker, check `-SyncPerFrame true` first —
   that is what fixes the foliage halo. Then `-GammaAsUnorm16 false`, then
   `-RtPath rov` as the oracle.
3. For frame rate, try `-FramesInFlight 1 -SyncPerFrame false`, a cheaper way
   to buy the same per-frame sync point.
4. If 2x is too slow, use `-Mode B` (1x + FSR) — it is the recommended
   configuration.

Keep VSync, patches, and the test location unchanged during each comparison.

Note that Xenia rewrites the profile TOML on exit — hex becomes decimal and new
cvars get appended. Command-line overrides are not written back.

`use_fuzzy_alpha_epsilon` is left off: it targets NVIDIA alpha-test flicker, not
opaque colored boxes, and can change transparency. `clear_memory_page_state` is
enabled because current Fable II reports associate it with reduced video
flicker. Synchronous shader compilation is kept on (async off) because skipped
draws while pipelines compile produce exactly the coloured buffers this profile
is trying to avoid.
