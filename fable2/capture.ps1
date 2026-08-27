<#
.SYNOPSIS
Launches Xenia under RenderDoc so a frame can be captured with a graphics
debugger.

.DESCRIPTION
Xenia's own GPU trace viewer cannot show render target or texture contents on
D3D12 - GetColorRenderTarget, GetDepthRenderTarget and GetTextureEntry are
unimplemented stubs - so there is no way to find a bad draw by eye in it.
RenderDoc gives per-draw render target previews, bound textures, and pixel
history, which is what actually identifies a rendering fault.

This writes a RenderDoc capture settings file matching the chosen mode and
opens RenderDoc on it. Press Launch in RenderDoc, play to the fault, then press
F12 (or PrintScreen) to capture.

.EXAMPLE
.\fable2\capture.ps1 -Mode B 'C:\Games\Fable II.iso'
.\fable2\capture.ps1 -Mode A -SyncPerFrame true 'C:\Games\Fable II.iso'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [ValidateSet("A", "B", "C")]
  [string]$Mode = "B",

  # Same overrides as run.ps1, for capturing a specific configuration.
  [ValidateSet("", "none", "fast", "full")]
  [string]$Readback = "",
  [ValidateSet("", "true", "false")]
  [string]$SyncPerFrame = "",
  [ValidateSet("", "rtv", "rov")]
  [string]$RtPath = "",
  [string[]]$Cvar = @(),

  [Parameter(Position = 0)]
  [string]$Target
)

$renderdoc = @(
  "$env:ProgramFiles\RenderDoc\qrenderdoc.exe"
  "${env:ProgramFiles(x86)}\RenderDoc\qrenderdoc.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if (!$renderdoc) {
  throw "RenderDoc not found. Install it with: winget install --id BaldurKarlsson.RenderDoc"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$xenia = Join-Path $repoRoot "build\bin\Windows\Release\xenia_canary.exe"
if (!(Test-Path -LiteralPath $xenia -PathType Leaf)) {
  throw "Release build not found. Run: .\xb.ps1 build --config=release"
}

$config = Join-Path $PSScriptRoot "fable2-2x-selective.config.toml"

$xeniaArguments = @(
  "--storage_root=$PSScriptRoot"
  "--config=$config"
  "--apply_patches=true"
  "--vsync=true"
  "--framerate_limit=0"
  # Stdout logging is synchronous; keep it out of the captured frame's timing.
  "--log_to_stdout=false"
)
if ($Mode -eq "B") {
  $xeniaArguments += "--draw_resolution_scale_x=1"
  $xeniaArguments += "--draw_resolution_scale_y=1"
  $xeniaArguments += "--postprocess_scaling_and_sharpening=fsr"
}
if ($Readback) { $xeniaArguments += "--readback_resolve=$Readback" }
if ($SyncPerFrame) { $xeniaArguments += "--await_gpu_completion_per_frame=$SyncPerFrame" }
if ($RtPath) { $xeniaArguments += "--render_target_path_d3d12=$RtPath" }
foreach ($override in $Cvar) {
  foreach ($pair in ($override -split ",")) {
    $pair = $pair.Trim()
    if (!$pair) { continue }
    if ($pair -notmatch "^[A-Za-z_][A-Za-z0-9_]*=") {
      throw "-Cvar entries must look like name=value, got: $pair"
    }
    $xeniaArguments += "--$pair"
  }
}
if ($Target) {
  $xeniaArguments += (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
}

# RenderDoc's .cap file is JSON. commandLine is a single string, so quote any
# argument containing spaces - every path here does.
$commandLine = ($xeniaArguments | ForEach-Object {
  if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
}) -join " "

$capturePath = Join-Path $PSScriptRoot "scratch\fable2-mode$Mode.cap"
New-Item -ItemType Directory -Force (Split-Path -Parent $capturePath) | Out-Null

$cap = [ordered]@{
  rdocCaptureSettings = 1
  settings = [ordered]@{
    autoStart        = $false
    commandLine      = $commandLine
    environment      = @()
    executable       = $xenia.Replace("\", "/")
    inject           = $false
    numQueuedFrames  = 0
    queuedFrameCap   = 0
    workingDir       = $repoRoot.Replace("\", "/")
    options = [ordered]@{
      allowFullscreen      = $true
      allowVSync           = $true
      apiValidation        = $false
      captureAllCmdLists   = $false
      captureCallstacks    = $false
      captureCallstacksOnlyDraws = $false
      debugOutputMute      = $true
      delayForDebugger     = 0
      hookIntoChildren     = $false
      refAllResources      = $false
      verifyBufferAccess   = $false
    }
  }
}

if (!$PSCmdlet.ShouldProcess($capturePath, "Write RenderDoc capture settings and open RenderDoc")) {
  exit 0
}

$cap | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $capturePath -Encoding utf8
Write-Host "Capture settings: $capturePath"
Write-Host "Command line:     $commandLine"
Write-Host ""
Write-Host "In RenderDoc: press Launch, play until the fault is on screen, then press F12."
Write-Host "The capture appears in the Launch Application tab; double-click it to open."

Start-Process -FilePath $renderdoc -ArgumentList "`"$capturePath`""
