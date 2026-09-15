<#
.SYNOPSIS
  Check whether oh-my-pi can draw inline images in this session.

.DESCRIPTION
  Read-only. Inspects the Windows Terminal version, the WT profile environment,
  the user environment, omp's terminal.showImages setting, and (when bun is
  available) the image protocol omp resolves for this shell. Prints what to do
  for anything that is off.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$RepoRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$failures = 0
$warnings = 0

function Check($name, $ok, $detail, $fix) {
    $label = if ($ok) { '[ok]' } else { '[!!]' }
    $color = if ($ok) { 'Green' } else { 'Yellow' }
    Write-Host ("{0} {1}" -f $label, $name) -ForegroundColor $color
    if ($detail) { Write-Host "     $detail" -ForegroundColor Gray }
    if (-not $ok -and $fix) { Write-Host "     fix: $fix" -ForegroundColor DarkYellow }
    if (-not $ok) { $script:failures++ }
}

Write-Host "`n== omp terminal images: verify" -ForegroundColor Cyan

# 1. Windows Terminal version
$pkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
if ($pkg) {
    $ok = ([version]$pkg.Version -ge [version]'1.22')
    Check "Windows Terminal >= 1.22" $ok "installed: $($pkg.Version)" "winget upgrade Microsoft.WindowsTerminal"
} else {
    Check "Windows Terminal package" $false 'not detected (conhost / VS Code terminal have no SIXEL)' 'install Windows Terminal or use Ghostty/WezTerm/kitty'
}

# 2. WT profile environment
$wtSettings = @(
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

if ($wtSettings) {
    $json = Get-Content -LiteralPath $wtSettings -Raw | ConvertFrom-Json
    $envMap = $json.profiles.defaults.environment
    $proto = $envMap.PI_FORCE_IMAGE_PROTOCOL
    $links = $envMap.PI_FORCE_HYPERLINKS
    Check "WT profiles.defaults.environment.PI_FORCE_IMAGE_PROTOCOL" ($proto -eq 'sixel') "value: $proto" "run install.ps1"
    Check "WT profiles.defaults.environment.PI_FORCE_HYPERLINKS" ($links -eq '1') "value: $links" "run install.ps1 (image chips become Ctrl+clickable)"
} else {
    Check 'Windows Terminal settings.json' $false 'not found' 'run install.ps1'
}

# 3. user environment
$userProto = [Environment]::GetEnvironmentVariable('PI_FORCE_IMAGE_PROTOCOL', 'User')
Check 'user env PI_FORCE_IMAGE_PROTOCOL' ($userProto -eq 'sixel') "value: $userProto" 'run install.ps1'

# 4. this process (only matters for terminals started before the install)
$procProto = $env:PI_FORCE_IMAGE_PROTOCOL
Check 'this process PI_FORCE_IMAGE_PROTOCOL' ($procProto -eq 'sixel') "value: $procProto" 'open a NEW Windows Terminal tab (or: set PI_FORCE_IMAGE_PROTOCOL=sixel)'

# 5. omp setting
$ompConfig = Join-Path $env:USERPROFILE '.omp\agent\config.yml'
if (Test-Path -LiteralPath $ompConfig) {
    $text = Get-Content -LiteralPath $ompConfig -Raw
    Check 'omp terminal.showImages' ($text -match '(?m)^\s*showImages\s*:\s*true\s*$') 'from ~/.omp/agent/config.yml' 'run install.ps1'
} else {
    Check 'omp config.yml' $false "not found: $ompConfig" 'run omp once, then re-run install.ps1'
}

# 6. resolved protocol (bun + @oh-my-pi/pi-tui)
$detect = Join-Path $RepoRoot 'tools\detect.mjs'
$bun = Get-Command bun -ErrorAction SilentlyContinue
if ($bun -and (Test-Path -LiteralPath $detect)) {
    Write-Host "`n-- protocol omp resolves for this shell" -ForegroundColor Cyan
    & $bun.Source $detect
    if ($LASTEXITCODE -ne 0) { $warnings++ }
} else {
    Write-Host "`n-- tools/detect.mjs skipped (bun not on PATH)" -ForegroundColor DarkGray
}

Write-Host "`n== summary" -ForegroundColor Cyan
if ($failures -eq 0) {
    Write-Host 'All checks passed. Final visual proof:' -ForegroundColor Green
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Yellow
}
Write-Host '  1. bun tools/sixel-card.mjs      -> must draw a picture in Windows Terminal'
Write-Host '  2. in omp: /terminal-info        -> Graphics: Sixel'
Write-Host '  3. in omp: /debug                -> graphics probe draws a sample image'
Write-Host '  4. bun tools/check-render.mjs    -> counts SIXEL escapes in a session transcript'
exit $failures
