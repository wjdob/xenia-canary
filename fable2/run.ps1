[CmdletBinding(DefaultParameterSetName = "Profile", SupportsShouldProcess)]
param(
  [Parameter(ParameterSetName = "Profile")]
  [ValidateSet("quality", "selective")]
  [string]$Profile = "quality",

  [Parameter(Mandatory, ParameterSetName = "UAT")]
  [ValidateSet("A", "B", "C")]
  [string]$Mode,

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
if ($Target) {
  $xeniaArguments += (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
}

$action = if ($isUat) { "Launch Xenia in UAT Mode $Mode ($modeDescription)" } else { "Launch Xenia with the $Profile profile" }
if (!$PSCmdlet.ShouldProcess($xenia, $action)) {
  exit 0
}

if ($isUat) {
  Write-Host "UAT $Mode`: VSync on, original MSAA, $modeDescription."
}

# Piping forces PowerShell to wait for this GUI executable.
& $xenia @xeniaArguments | Out-Host
exit $LASTEXITCODE
