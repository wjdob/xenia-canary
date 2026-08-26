[CmdletBinding(DefaultParameterSetName = "Profile", SupportsShouldProcess)]
param(
  [Parameter(ParameterSetName = "Profile")]
  [ValidateSet("quality", "selective")]
  [string]$Profile = "quality",

  [Parameter(Mandatory, ParameterSetName = "UAT")]
  [ValidateSet("A", "B", "C")]
  [string]$Mode,

  # Render target emulation path. "rov" is the accuracy oracle for colored
  # buffers and wrong-color effects; it is slower and not a shipping setting.
  [ValidateSet("", "rtv", "rov")]
  [string]$RtPath = "",

  # Surface pitch at or below which render targets stay at native resolution.
  # 80 and 160 keep small bloom / light-shaft targets unscaled.
  [int]$ScaleThreshold = -1,

  # Emulate 8_8_8_8_GAMMA render targets as 16-bit unorm. Turning this off is
  # the first thing to try for wrong colors on bright effects.
  [ValidateSet("", "true", "false")]
  [string]$GammaAsUnorm16 = "",

  # CPU readback of resolve results. The two profiles differ here, so this is
  # how to hold it fixed while changing something else.
  [ValidateSet("", "none", "fast", "full")]
  [string]$Readback = "",

  # Final-output resampling/sharpening. The two profiles also differ here.
  [ValidateSet("", "bilinear", "cas", "fsr")]
  [string]$Sharpening = "",

  # Wait for the GPU to go idle once at the end of each frame. Some titles only
  # render correctly when something forces a CPU-GPU sync; this gives them one
  # stall per frame instead of one per resolve.
  [ValidateSet("", "true", "false")]
  [string]$SyncPerFrame = "",

  # How many frames the CPU may run ahead of the GPU. 1 forces a per-frame sync
  # like -SyncPerFrame but waits for the previous frame rather than a full GPU
  # idle, so it is cheaper. -1 keeps the backend default of 3.
  [ValidateRange(-1, 3)]
  [int]$FramesInFlight = -1,

  # Emulate guest 24-bit float depth exactly, as the ROV backend always does:
  # depth_float24_convert_in_pixel_shader + depth_float24_round. Shadow-map
  # striping ("acne") is a depth-precision artifact, so this is the first thing
  # to try for it on the RTV path.
  [switch]$ExactDepth24,

  # Log the register signature of every distinct resolve the title issues.
  [switch]$LogResolves,

  # Restrict readback to one guest region, as "start,length" or "start" for a
  # 1 MB window. Readback cost scales with the number of resolves read back,
  # so narrowing it to the region the game actually reads keeps correctness at
  # a fraction of the price.
  [string]$ReadbackRange = "",

  # Log textures that a scaled resolve wrote but that have to be read from
  # shared memory instead of the scaled resolve buffer - the ones most likely
  # to look stale or flicker at 2x.
  [switch]$LogUnscaledTextures,

  # 0 = error, 1 = warning, 2 = info (default), 3 = debug. Level 3 surfaces
  # every readback skip but costs a lot of frame time.
  [ValidateRange(-1, 3)]
  [int]$LogLevel = -1,

  # Suppress stdout logging. Measured runs should always use this - stdout
  # logging is synchronous and distorts frame times.
  [switch]$Quiet,

  [Parameter(Position = 0)]
  [string]$Target
)

# Start-Process joins -ArgumentList with spaces and does no quoting of its own,
# and every path here contains spaces. Quote each argument per the Windows CRT
# command-line rules so they survive as single tokens.
function Format-NativeArgument([string]$Argument) {
  if ($Argument -notmatch '[\s"]') { return $Argument }
  # Double the backslashes that precede a quote, and escape the quote.
  $escaped = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
  # Double a trailing backslash run so it doesn't escape the closing quote.
  $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
  return '"' + $escaped + '"'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$xenia = Join-Path $repoRoot "build\bin\Windows\Release\xenia_canary.exe"
$isUat = $PSCmdlet.ParameterSetName -eq "UAT"
$configProfile = if ($isUat) { "selective" } else { $Profile }
$config = Join-Path $PSScriptRoot "fable2-2x-$configProfile.config.toml"

if (!(Test-Path -LiteralPath $xenia -PathType Leaf)) {
  throw "Release build not found. Run: .\xb.ps1 build --config=release"
}

$xeniaArguments = @(
  "--storage_root=$PSScriptRoot"
  "--config=$config"
)
if ($isUat) {
  $xeniaArguments += "--apply_patches=true"
  $xeniaArguments += "--vsync=true"
  $xeniaArguments += "--framerate_limit=0"
  if ($Mode -eq "B") {
    $xeniaArguments += "--draw_resolution_scale_x=1"
    $xeniaArguments += "--draw_resolution_scale_y=1"
    $xeniaArguments += "--postprocess_scaling_and_sharpening=fsr"
  }
  $modeDescription = switch ($Mode) {
    "A" { "2x + CAS" }
    "B" { "1x + FSR" }
    "C" { "2x + CAS, readback restricted to the exposure region" }
  }
  # Mode C is now the narrow-readback candidate: full readback, but only for
  # the small luminance/exposure destinations, which is where the guest-side
  # feedback loop reads. Overridable with -ReadbackRange.
  if ($Mode -eq "C" -and !$ReadbackRange) {
    $ReadbackRange = "0x1B600000,0x800000"
  }
}

# Experiment overrides, applicable to both profile and UAT launches. These come
# after the mode block so they win over its defaults.
if ($Readback) { $xeniaArguments += "--readback_resolve=$Readback" }
if ($ReadbackRange) {
  $rangeParts = $ReadbackRange -split ","
  $rangeStart = $rangeParts[0].Trim()
  $rangeLength = if ($rangeParts.Count -gt 1) { $rangeParts[1].Trim() } else { "0x100000" }
  $xeniaArguments += "--readback_resolve_range_start=$rangeStart"
  $xeniaArguments += "--readback_resolve_range_length=$rangeLength"
}
if ($Sharpening) { $xeniaArguments += "--postprocess_scaling_and_sharpening=$Sharpening" }
if ($RtPath) { $xeniaArguments += "--render_target_path_d3d12=$RtPath" }
if ($ScaleThreshold -ge 0) { $xeniaArguments += "--draw_resolution_scale_threshold=$ScaleThreshold" }
if ($GammaAsUnorm16) { $xeniaArguments += "--gamma_render_target_as_unorm16=$GammaAsUnorm16" }
if ($SyncPerFrame) { $xeniaArguments += "--await_gpu_completion_per_frame=$SyncPerFrame" }
if ($FramesInFlight -ge 0) { $xeniaArguments += "--gpu_frames_in_flight=$FramesInFlight" }
if ($ExactDepth24) {
  $xeniaArguments += "--depth_float24_convert_in_pixel_shader=true"
  $xeniaArguments += "--depth_float24_round=true"
}
if ($LogResolves) { $xeniaArguments += "--log_resolves=true" }
if ($LogUnscaledTextures) { $xeniaArguments += "--log_unscaled_resolve_textures=true" }
if ($LogLevel -ge 0) { $xeniaArguments += "--log_level=$LogLevel" }
if ($Quiet) { $xeniaArguments += "--log_to_stdout=false" }

if ($Target) {
  $xeniaArguments += (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
}

$action = if ($isUat) { "Launch Xenia in UAT Mode $Mode ($modeDescription)" } else { "Launch Xenia with the $Profile profile" }
if (!$PSCmdlet.ShouldProcess($xenia, $action)) {
  exit 0
}

# Every run prints the overrides it actually used, so a result recorded in
# UAT_RESULTS.md can be tied back to an exact configuration.
$manifest = ($xeniaArguments | Where-Object { $_ -like "--*" }) -join " "
if ($isUat) {
  Write-Host "UAT $Mode`: $modeDescription."
}
Write-Host "Run manifest: $manifest"

# Start-Process -Wait keeps the emulator's stdout off the PowerShell pipeline;
# piping it through the host serializes every log line and distorts frame times.
$quotedArguments = @($xeniaArguments | ForEach-Object { Format-NativeArgument $_ })
$process = Start-Process -FilePath $xenia -ArgumentList $quotedArguments -PassThru -Wait
exit $process.ExitCode
