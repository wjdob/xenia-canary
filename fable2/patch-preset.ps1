<#
.SYNOPSIS
Sets is_enabled on the Fable II patch bundle to a named preset.

.DESCRIPTION
The blue/pink foliage light needs a bisect of the render-config patches, and
hand-editing the TOML between runs loses track of what was actually tested.
This toggles only the entries a preset names and leaves every other patch
alone, so a run can be tied to a preset name in UAT_RESULTS.md.

600p writes 0x58 at 0x8238df4f and Disable MSAA writes 0x01 at 0x8238df3f -
16 bytes apart, so they are almost certainly fields of the same render-config
structure. 600p exists to fix strobing under the game's original MSAA, so with
MSAA disabled it may no longer be helping.

.EXAMPLE
.\fable2\patch-preset.ps1 -Preset P2
.\fable2\patch-preset.ps1 -Show
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  # P0: current state - 600p on, MSAA disabled, morph disabled.
  # P1: 600p on, game MSAA restored. Already tested - no change.
  # P2: 600p off, MSAA disabled.
  # P3: 600p off, game MSAA restored. Closest to the stock render config.
  [ValidateSet("P0", "P1", "P2", "P3")]
  [string]$Preset,

  # Print the current is_enabled state and exit.
  [switch]$Show
)

$patchFile = Join-Path $PSScriptRoot "patches\4D5307F1 - Fable II (GOTY_Platinum Edition, Femtofork Extras).patch.toml"
if (!(Test-Path -LiteralPath $patchFile -PathType Leaf)) {
  throw "Patch file not found: $patchFile"
}

$k600p = "600p Resolution (Fixes Strobe)"
$kMsaa = "Disable MSAA (Multi-Sample Anti-Aliasing)"

$presets = @{
  "P0" = @{ $k600p = "true";  $kMsaa = "true"  }
  "P1" = @{ $k600p = "true";  $kMsaa = "false" }
  "P2" = @{ $k600p = "false"; $kMsaa = "true"  }
  "P3" = @{ $k600p = "false"; $kMsaa = "false" }
}

$originalText = [System.IO.File]::ReadAllText($patchFile)
$hadTrailingNewline = $originalText.EndsWith("`n")
$lines = [System.IO.File]::ReadAllLines($patchFile)

if ($Show -or !$Preset) {
  $currentName = $null
  foreach ($line in $lines) {
    if ($line -match '^\s*name\s*=\s*"(.*)"') { $currentName = $Matches[1] }
    elseif ($line -match '^\s*is_enabled\s*=\s*(true|false)') {
      "{0,-5} {1}" -f $Matches[1], $currentName
    }
  }
  if (!$Preset) { exit 0 }
}

$overrides = $presets[$Preset]
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

if (!$changed) {
  Write-Host "Preset $Preset already applied - no changes."
  exit 0
}

if (!$PSCmdlet.ShouldProcess($patchFile, "Apply patch preset $Preset")) {
  exit 0
}

# CRLF, and preserve whether the file ended with a newline, so the diff is
# limited to the toggled lines.
$text = $lines -join "`r`n"
if ($hadTrailingNewline) { $text += "`r`n" }
[System.IO.File]::WriteAllText($patchFile, $text)
Write-Host "Applied preset $Preset`:"
$changed | ForEach-Object { Write-Host "  $_" }
