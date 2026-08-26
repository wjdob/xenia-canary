# Fable II UAT results

One row per measured run. Keep every other variable fixed within a comparison:
same save, same route, same camera, same output resolution, same driver
settings, and a similar starting GPU temperature.

Always warm the shader cache on the route before recording, and always launch
measured runs with `-Quiet` so stdout logging isn't in the frame-time path.

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

| Preset | 600p | Disable MSAA | Disable Morph |
|--------|------|--------------|---------------|
| P0 | on | on | on |
| P1 | on | off | on |
| P2 | off | on | on |
| P3 | off | off | on |

Apply with `.\fable2\patch-preset.ps1 -Preset P2`.

## Runs

| Date | Mode | Preset | Overrides | Min FPS | 1% low / frame time | GPU % | GPU °C | GPU clock | VRAM | CPU % | Visual notes |
|------|------|--------|-----------|---------|---------------------|-------|--------|-----------|------|-------|--------------|
| | | | | | | | | | | | |

Paste the `Run manifest:` line the launcher prints into **Overrides** — it is
the exact set of command-line overrides that run used.

## Historical results (pre-instrumentation)

These predate the current patch bundle and the readback instrumentation, and
are **not** an apples-to-apples baseline for new runs.

- Mode A ≈ 20 FPS at its low point, Mode B ≈ 31 FPS, with 60 FPS and High Tick
  Rate enabled and the earlier four-patch bundle.
- An earlier, more aggressive Mode B showed graphics glitches; Mode A was more
  stable at roughly 23 FPS at its low point.
- Before `Disable Texture Morphing` was added, the hero and dog were black in
  all three modes.
