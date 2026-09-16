<#
.SYNOPSIS
  Check whether oh-my-pi can draw inline images in this session.

.DESCRIPTION
  Read-only. Inspects the Windows Terminal version, the WT profile environment,
  the user environment, this process' environment, omp's terminal.showImages
  setting, the protocol omp resolves for this shell, and whether the installed
  omp bundle carries the pasted-image patch.

  The exit code is the number of problems found: failed checks plus warnings.
  It always matches the printed summary, so a runner can gate on it.

.PARAMETER Headless
  Run only the checks that need no GUI or TTY (Windows Terminal version, WT
  profile environment, user environment, this process' environment, config.yml,
  tools/detect.mjs, and the pasted-image patch), skip the visual-proof
  instructions, and exit with the real code.

.EXAMPLE
  pwsh -File verify.ps1 -Headless    # runner-friendly, exit code = problem count
.EXAMPLE
  pwsh -File verify.ps1              # same checks, plus the manual visual proofs
#>
[CmdletBinding()]
param(
    [switch]$Headless
)

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
function Warn($name, $detail) {
    $script:warnings++
    Write-Host ("[!!] {0}" -f $name) -ForegroundColor Yellow
    if ($detail) { Write-Host "     $detail" -ForegroundColor Gray }
}

Write-Host "`n== omp terminal images: verify" -ForegroundColor Cyan
if ($Headless) { Write-Host '   headless: GUI/TTY proofs are skipped' -ForegroundColor DarkGray }

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
    $json = $null
    try { $json = Get-Content -LiteralPath $wtSettings -Raw | ConvertFrom-Json } catch { $json = $null }
    if (-not $json) {
        Check 'Windows Terminal settings.json' $false "unreadable JSON: $wtSettings" 'fix settings.json in Windows Terminal (Ctrl+,)'
    } elseif ($json.profiles -is [array]) {
        Check 'WT profiles.defaults.environment' $false 'profiles is written as an array; the object form {"profiles":{"defaults":{"environment":{...}}}} is required for a default environment' 'set the variables in Windows Terminal settings (Profiles > Defaults > Environment)'
    } else {
        $envMap = $json.profiles.defaults.environment
        $proto = $envMap.PI_FORCE_IMAGE_PROTOCOL
        $links = $envMap.PI_FORCE_HYPERLINKS
        Check "WT profiles.defaults.environment.PI_FORCE_IMAGE_PROTOCOL" ($proto -eq 'sixel') "value: $proto" "run install.ps1"
        Check "WT profiles.defaults.environment.PI_FORCE_HYPERLINKS" ($links -eq '1') "value: $links" "run install.ps1 (image chips become Ctrl+clickable)"
    }
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
    if ($LASTEXITCODE -ne 0) { Warn 'tools/detect.mjs' "exited $LASTEXITCODE - this shell's protocol could not be resolved" }
} else {
    Write-Host "`n-- tools/detect.mjs skipped (bun not on PATH)" -ForegroundColor DarkGray
}

# 7. pasted-image patch
$patchTool = Join-Path $RepoRoot 'tools\patch-paste-images.mjs'
if ($bun -and (Test-Path -LiteralPath $patchTool)) {
    Write-Host "`n-- pasted images (composer card + transcript entry)" -ForegroundColor Cyan
    $raw = @(& $bun.Source $patchTool check --json 2>&1 | ForEach-Object { [string]$_ })
    $text = $raw -join "`n"
    $st = $null
    $start = $text.IndexOf('{')
    if ($start -ge 0) { try { $st = $text.Substring($start) | ConvertFrom-Json } catch { $st = $null } }

    if ($st) {
        $detail = "omp $($st.ompVersion) - $($st.cliPath)"
        if ($st.patched -and -not $st.stale) {
            Check 'omp bundle carries the pasted-image patch' $true "patch rev $($st.patchRev), $detail" $null
        } elseif ("$($st.reason)" -like 'unsatisfiable:*') {
            Check 'omp bundle carries the pasted-image patch' $false "$($st.reason) - re-running install.ps1 cannot fix this: the omp build is not one this patch understands, so tools/patch-paste-images.mjs needs updating (or a matching omp build installed)" 'bun tools/patch-paste-images.mjs check'
        } elseif ($st.stale) {
            Check 'omp bundle carries the pasted-image patch' $false "stale: $($st.reason) - $detail" 'run install.ps1 (re-applies the patch after an omp upgrade)'
        } else {
            Check 'omp bundle carries the pasted-image patch' $false "not applied: $($st.reason) - $detail" 'run install.ps1 (or: bun tools/patch-paste-images.mjs apply)'
        }
    } else {
        # Patcher without `check --json` (older checkout): fall back to `status`.
        $status = @(& $bun.Source $patchTool status 2>&1 | ForEach-Object { [string]$_ })
        $status | ForEach-Object { Write-Host "     $_" -ForegroundColor Gray }
        $patched = ($status -join "`n") -match '(?m)^patched\s+yes'
        Check 'omp bundle carries the pasted-image patch' $patched 'pasted images draw as pictures, not chips' 'run install.ps1 (or: bun tools/patch-paste-images.mjs apply)'
    }
} else {
    Write-Host "`n-- pasted-image patch skipped (bun or tools/patch-paste-images.mjs missing)" -ForegroundColor DarkGray
}

$problems = $failures + $warnings
Write-Host "`n== summary" -ForegroundColor Cyan
if ($failures -eq 0 -and $warnings -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
} else {
    Write-Host "$failures check(s) failed, $warnings warning(s)." -ForegroundColor Yellow
}
Write-Host "exit code $problems" -ForegroundColor $(if ($problems -eq 0) { 'Green' } else { 'Yellow' })

if (-not $Headless) {
    Write-Host 'Final visual proof (needs Windows Terminal and a real omp session):'
    Write-Host '  1. bun tools/sixel-card.mjs      -> must draw a picture in Windows Terminal'
    Write-Host '  2. in omp: /debug -> "Test: terminal protocols" -> Graphics - Sixel'
    Write-Host '  3. bun tools/check-render.mjs    -> counts SIXEL escapes in a session transcript'
    Write-Host '  4. pwsh -File tools/live-tui-proof.ps1 [-Scenario paste|debug]'
    Write-Host '     -> drives a real omp in its own WT window and screenshots it into docs/'
}

exit $problems
