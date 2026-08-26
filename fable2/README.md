# Fable II profile

Xenia Canary with a Fable II profile, launcher and patch bundle.

The old femtofork's selective-readback idea was ported, tested, and removed: its
signature never matched this build, and readback does not fix the morph
textures. What the investigation produced instead is general and stayed in —
resolve logging, readback skip reporting, submission fences on the readback
buffers, and a readback destination range filter.

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

- `selective`: `readback_resolve = "full"` plus CAS. **This is the visually
  correct configuration** — `"none"` gives a constant magenta halo behind
  foliage and `"fast"` makes it strobe. A/B/C all use it. It is also slow.
- `quality` (default): `readback_resolve = "fast"`, no sharpening. Faster, but
  it strobes.

The profile names are historical; "selective" no longer refers to anything.

```powershell
.\fable2\run.ps1 -Profile selective
```

## A/B/C UAT

These modes use the same profile and shader cache, force VSync on, and apply
the same enabled game patches:

```powershell
.\fable2\run.ps1 -Mode A "D:\Games\Fable II.iso" # 2x + CAS, full readback
.\fable2\run.ps1 -Mode B "D:\Games\Fable II.iso" # 1x + FSR, full readback
.\fable2\run.ps1 -Mode C "D:\Games\Fable II.iso" # 2x + CAS, readback narrowed
```

A and B differ only in resolution and sharpening. Mode C is the performance
candidate: the same as A, but with readback restricted to `0x1B600000 +
0x800000` — the small destinations most likely to be what the guest reads back.

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

`-ReadbackRange` is the performance lever. `full` readback is visually correct
but costs about half the frame rate, and the cost scales with the *number* of
resolves read back rather than their size — so restricting readback to the one
region the guest actually reads should keep the correctness cheaply. The
bisection list is in [CONTEXT_HANDOFF.md](CONTEXT_HANDOFF.md).

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
2. For wrong-colour effects or flicker, the first thing to check is
   `-Readback full` — that is what fixed the foliage halo. Then
   `-GammaAsUnorm16 false`, then `-RtPath rov` as the oracle.
3. For frame rate, narrow the readback with `-ReadbackRange` rather than
   turning it off.
4. If 2x is too slow, use `-Mode B` (1x + FSR).

Keep VSync, patches, and the test location unchanged during each comparison.

Note that Xenia rewrites the profile TOML on exit — hex becomes decimal and new
cvars get appended. Command-line overrides are not written back.

`use_fuzzy_alpha_epsilon` is left off: it targets NVIDIA alpha-test flicker, not
opaque colored boxes, and can change transparency. `clear_memory_page_state` is
enabled because current Fable II reports associate it with reduced video
flicker. Synchronous shader compilation is kept on (async off) because skipped
draws while pipelines compile produce exactly the coloured buffers this profile
is trying to avoid.
