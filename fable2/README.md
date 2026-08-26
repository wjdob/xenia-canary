# Fable II profile

This keeps current Xenia Canary and ports only the old femtofork's useful
game-specific idea: selective readback for the known player/dog morph-texture
resolve. Canary's newer GPU downscaler handles 2x readback; the old CPU
downscaler and renderer plumbing were intentionally not copied.

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

- `selective`: `readback_resolve = "full"` plus CAS. **This is the clean
  configuration** - testing showed `"none"` gives a constant magenta halo behind
  foliage and `"fast"` makes it strobe. A/B/C all use it.
- `quality` (default): `readback_resolve = "fast"`, no sharpening. Kept as the
  cheaper comparison point; it strobes.

```powershell
.\fable2\run.ps1 -Profile selective
```

The profile names are historical. The "selective" femtofork signature never
matches this build, so `fable2_selective_readback_resolve` does nothing; the
profile is just the one with the correct readback setting.

## A/B/C UAT

These modes use the same selective profile and shader cache, force VSync on,
and apply the same enabled game patches:

```powershell
.\fable2\run.ps1 -Mode A "D:\Games\Fable II.iso" # 2x + CAS
.\fable2\run.ps1 -Mode B "D:\Games\Fable II.iso" # 1x + FSR
.\fable2\run.ps1 -Mode C "D:\Games\Fable II.iso" # 2x + CAS, previous-frame readback
```

Modes A and B use immediate selective readback. Mode C differs from A only by
using the previous frame's readback buffer. That buffer now waits on the
submission that wrote it before being mapped, so it is one frame stale by
design rather than potentially torn.

Record results in [UAT_RESULTS.md](UAT_RESULTS.md). Always add `-Quiet` to
measured runs — stdout logging is synchronous and distorts frame times.

## Diagnostics

The readback path has several early exits that used to fail silently, which is
why a game could get no readback at all with nothing in the log. They are now
reported as warnings at the default log level, rate-limited after the first
occurrence.

```powershell
# What resolves does the game actually issue, and does one match the signature?
.\fable2\run.ps1 -Mode A -LogResolves -Quiet "D:\Games\Fable II.iso"

# Retarget the signature at a different destination (0 matches any).
.\fable2\run.ps1 -Mode A -ResolveDest 0x12704000 "D:\Games\Fable II.iso"
```

Look for these lines in `build/bin/Windows/Release/xenia.log`:

- `Fable II morph resolve signature matched ...` — the signature is being hit.
- `Fable II selective readback delivered ...` — data actually reached the guest.
- `Resolve readback to 0x... skipped because ...` — it matched but was dropped;
  the reason names which prerequisite failed.

If the first line never appears, the signature is wrong: run with
`-LogResolves` and pick the destination from the printed table.

## Experiment switches

```powershell
.\fable2\run.ps1 -Mode A -Readback fast          # the profiles differ here
.\fable2\run.ps1 -Mode A -Sharpening bilinear    # and here
.\fable2\run.ps1 -Mode A -GammaAsUnorm16 false   # wrong colours on bright effects
.\fable2\run.ps1 -Mode A -RtPath rov             # accuracy oracle, slower
.\fable2\run.ps1 -Mode A -LogLevel 3             # everything, very slow
```

`-ScaleThreshold` also exists, but **do not use it with Fable II**. Mixing 2x
and native render targets breaks this game's heavy EDRAM aliasing: at 640 the
whole scene blows out to white, blue and magenta. It is faster, and completely
unusable.

`-Readback` and `-Sharpening` exist because the `quality` and `selective`
profiles differ in exactly those two settings and nothing else that matters, so
they are the way to hold one fixed while changing the other. Overrides are
applied after the mode defaults, and Xenia's parser takes the last occurrence
of a flag, so `-Mode B -Sharpening bilinear` does override Mode B's FSR.

`rov` is the pixel-shader-interlock render backend. It is the diagnostic to
reach for when an effect comes out the wrong colour: if the artifact disappears
under ROV, the RTV path's EDRAM ownership transfer or format handling is at
fault. It is not a shipping setting.

## Patches

The active bundle is in [patches/](patches/). Inspect and toggle it with:

```powershell
.\fable2\patch-preset.ps1 -Show
.\fable2\patch-preset.ps1 -Preset P2
```

Currently enabled: 600p Resolution, Skip intro videos (twice — redundant but
intentional), 60 FPS, High Tick Rate, Unlock Website Items, Disable Texture
Morphing, Disable MSAA, Unlock Collectors Edition Content.

`Disable Texture Morphing` is what fixes the black hero and dog textures — not
the selective readback code. Testing has shown the selective signature never
matches, and that even global `readback_resolve = "fast"` leaves the hero and
dog black, so readback is not the mechanism at all. Keep this patch enabled.

Toggle morphing back on for testing with `.\fable2\patch-preset.ps1 -Morph on`,
and restore with `-Morph off`.

`Disable MSAA` and `600p Resolution` write 16 bytes apart in what is almost
certainly the same render-config structure. `600p` exists to fix strobing under
the game's *original* MSAA, so the two are not independent — that is what the
P0–P3 presets exist to bisect.

## Test order

1. Start with `quality`. Check the opening, first outdoor area, hero
   adulthood/makeup, dog appearance, and the clothing menu.
2. Repeat with `selective`, comparing frame pacing and the hero/dog textures.
   `full` readback is correct but stalls the GPU on every resolve, so this
   comparison is now mainly about cost.
3. For colored boxes or wrong-colour effects, first try `-Readback full` - that
   is what fixed the foliage halo. Then `-GammaAsUnorm16 false`, then
   `-RtPath rov` as the oracle.
4. If 2x is too slow, use `-Mode B` (1x + FSR).

Keep VSync, patches, and the test location unchanged during each comparison.

`use_fuzzy_alpha_epsilon` is left off: it targets NVIDIA alpha-test flicker,
not opaque colored boxes, and can change transparency. `clear_memory_page_state`
is enabled because current Fable II reports associate it with reduced video
flicker. Synchronous shader compilation is kept on (async off) because skipped
draws while pipelines compile produce exactly the coloured buffers this profile
is trying to avoid.
