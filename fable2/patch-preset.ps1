<#
.SYNOPSIS
Toggles entries in the Fable II patch bundle by name.

.DESCRIPTION
Hand-editing the TOML between test runs loses track of what was actually
tested. This toggles only the entries you name and leaves every other patch
alone, so a run can be tied to a preset name in UAT_RESULTS.md.

-Preset bisects the two render-config patches. 600p writes 0x58 at 0x8238df4f
and Disable MSAA writes 0x01 at 0x8238df3f - 16 bytes apart, so they are almost
certainly fields of the same structure. 600p exists to fix strobing under the
game's original MSAA, so with MSAA disabled it may no longer be helping.

-Morph is independent: "Disable Texture Morphing" is what currently masks the
black hero and dog. Turn morphing back on to test whether the emulator renders
them correctly by itself.

.EXAMPLE
.\fable2\patch-preset.ps1 -Show
.\fable2\patch-preset.ps1 -Preset P2
.\fable2\patch-preset.ps1 -Morph on
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  # P0: current state - 600p on, game MSAA disabled.
  # P1: 600p on, game MSAA restored. Already tested - no change.
  # P2: 600p off, game MSAA disabled.
  # P3: 600p off, game MSAA restored. Closest to the stock render config.
  [ValidateSet("P0", "P1", "P2", "P3")]
  [string]$Preset,

  # "on" lets the game morph textures (the disabling patch is turned off).
  # "off" restores the workaround.
  [ValidateSet("", "on", "off")]
  [string]$Morph = "",

  # Print the current is_enabled state and exit.
  [switch]$Show
)

$patchFile = Join-Path $PSScriptRoot "patches\4D5307F1 - Fable II (GOTY_Platinum Edition, Femtofork Extras).patch.toml"
if (!(Test-Path -LiteralPath $patchFile -PathType Leaf)) {
  throw "Patch file not found: $patchFile"
}

$k600p = "600p Resolution (Fixes Strobe)"
$kMsaa = "Disable MSAA (Multi-Sample Anti-Aliasing)"
$kMorph = "Disable Texture Morphing"

$presets = @{
  "P0" = @{ $k600p = "true";  $kMsaa = "true"  }
  "P1" = @{ $k600p = "true";  $kMsaa = "false" }
  "P2" = @{ $k600p = "false"; $kMsaa = "true"  }
  "P3" = @{ $k600p = "false"; $kMsaa = "false" }
}

$originalText = [System.IO.File]::ReadAllText($patchFile)
$hadTrailingNewline = $originalText.EndsWith("`n")
$lines = [System.IO.File]::ReadAllLines($patchFile)

if ($Show -or (!$Preset -and !$Morph)) {
  $currentName = $null
  foreach ($line in $lines) {
    if ($line -match '^\s*name\s*=\s*"(.*)"') { $currentName = $Matches[1] }
    elseif ($line -match '^\s*is_enabled\s*=\s*(true|false)') {
      "{0,-5} {1}" -f $Matches[1], $currentName
    }
  }
  if (!$Preset -and !$Morph) { exit 0 }
}

$overrides = @{}
if ($Preset) {
  foreach ($entry in $presets[$Preset].GetEnumerator()) {
    $overrides[$entry.Key] = $entry.Value
  }
}
if ($Morph) {
  # Morphing on means the disabling patch is off.
  $overrides[$kMorph] = if ($Morph -eq "off") { "true" } else { "false" }
}

$currentName = $null
$changed = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^\s*name\s*=\s*"(.*)"') {
    $currentName = $Matches[1]
    continue
  }
  if ($lines[$i] -match '^(\s*)is_enabled\s*=\s*(true|false)\s*$' -and
      $currentName -and $overrides.ContainsKey($currentName)) {
    $want = $overrides[$currentName]
    if ($Matches[2] -ne $want) {
      $lines[$i] = "$($Matches[1])is_enabled = $want"
      $changed += "$currentName -> $want"
    }
  }
}

$what = @()
if ($Preset) { $what += "preset $Preset" }
if ($Morph) { $what += "morph $Morph" }
$what = $what -join ", "

if (!$changed) {
  Write-Host "Already applied ($what) - no changes."
  exit 0
}

if (!$PSCmdlet.ShouldProcess($patchFile, "Apply $what")) {
  exit 0
}

# CRLF, and preserve whether the file ended with a newline, so the diff is
# limited to the toggled lines.
$text = $lines -join "`r`n"
if ($hadTrailingNewline) { $text += "`r`n" }
[System.IO.File]::WriteAllText($patchFile, $text)
Write-Host "Applied ${what}:"
$changed | ForEach-Object { Write-Host "  $_" }
