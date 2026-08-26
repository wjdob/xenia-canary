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

  # Log the register signature of every distinct Fable II resolve.
  [switch]$LogResolves,

  # Resolve destination the selective morph readback matches. 0 matches any.
  [string]$ResolveDest = "",

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
  $selectiveFast = if ($Mode -eq "C") { "true" } else { "false" }
  $xeniaArguments += "--fable2_selective_readback_resolve_fast=$selectiveFast"
  if ($Mode -eq "B") {
    $xeniaArguments += "--draw_resolution_scale_x=1"
    $xeniaArguments += "--draw_resolution_scale_y=1"
    $xeniaArguments += "--postprocess_scaling_and_sharpening=fsr"
  }
  $modeDescription = switch ($Mode) {
    "A" { "2x + CAS, immediate selective readback" }
    "B" { "1x + FSR, immediate selective readback" }
    "C" { "2x + CAS, previous-frame selective readback" }
  }
}

# Experiment overrides, applicable to both profile and UAT launches.
if ($RtPath) { $xeniaArguments += "--render_target_path_d3d12=$RtPath" }
if ($ScaleThreshold -ge 0) { $xeniaArguments += "--draw_resolution_scale_threshold=$ScaleThreshold" }
if ($GammaAsUnorm16) { $xeniaArguments += "--gamma_render_target_as_unorm16=$GammaAsUnorm16" }
if ($LogResolves) { $xeniaArguments += "--fable2_log_resolves=true" }
if ($ResolveDest) { $xeniaArguments += "--fable2_selective_readback_resolve_dest=$ResolveDest" }
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
$process = Start-Process -FilePath $xenia -ArgumentList $xeniaArguments -PassThru -Wait
exit $process.ExitCode
