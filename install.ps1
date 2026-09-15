<#
.SYNOPSIS
  Make oh-my-pi (omp) render inline images on Windows Terminal.

.DESCRIPTION
  Pins PI_FORCE_IMAGE_PROTOCOL=sixel for Windows Terminal sessions (WT never
  answers omp's XTSMGRAPHICS capability probe, so the automatic detection leaves
  images as "[Image: ...]" text cards), enables OSC 8 hyperlinks so image chips
  are clickable, and makes sure omp's terminal.showImages setting is on.

  Idempotent. Backs up every file it touches as "<file>.bak-ompimages".
  Requires Windows Terminal >= 1.22 for SIXEL rendering.

.PARAMETER Uninstall
  Remove the environment entries this script added and restore settings.json.

.PARAMETER DryRun
  Print what would change without writing anything.

.PARAMETER CleanProfiles
  Collapse duplicated "$env:PI_FORCE_IMAGE_PROTOCOL = 'sixel'" lines left in
  PowerShell profiles down to one.

.PARAMETER SkipUserEnv
  Do not touch the user-level environment variables (WT profile env only).
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$CleanProfiles,
    [switch]$SkipUserEnv
)

$ErrorActionPreference = 'Stop'

$ProtocolValue = 'sixel'
$HyperlinkValue = '1'
$BackupSuffix = '.bak-ompimages'
$WtEnvKeys = @{
    'PI_FORCE_IMAGE_PROTOCOL' = $ProtocolValue
    'PI_FORCE_HYPERLINKS'     = $HyperlinkValue
}

function Write-Step($msg) { Write-Host "  $msg" }
function Write-Head($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "  [ok] $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "  [--] $msg" -ForegroundColor DarkGray }
function Write-Warn2($msg) { Write-Host "  [!!] $msg" -ForegroundColor Yellow }

function Get-WtSettingsPath {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Backup-Once([string]$Path) {
    $backup = "$Path$BackupSuffix"
    if ($DryRun) { Write-Step "would back up $Path -> $backup"; return }
    Copy-Item -LiteralPath $Path -Destination $backup -Force
    Write-Step "backed up -> $backup"
}

# UTF8 without BOM: a BOM makes Windows Terminal reject settings.json.
function Save-Text([string]$Path, [string]$Text) {
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Get-WtVersion {
    $pkg = Get-AppxPackage -Name Microsoft.WindowsTerminal -ErrorAction SilentlyContinue
    if (-not $pkg) { return $null }
    return [version]$pkg.Version
}

# ---------------------------------------------------------------- settings.json
function Set-WtSettings([bool]$Remove) {
    $path = Get-WtSettingsPath
    if (-not $path) { Write-Warn2 'Windows Terminal settings.json not found; skipping profile environment'; return }
    Write-Step "settings.json: $path"

    $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($null -eq $json.profiles) { $json | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($null -eq $json.profiles.defaults) { $json.profiles | Add-Member -NotePropertyName defaults -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($null -eq $json.profiles.defaults.environment) {
        $json.profiles.defaults | Add-Member -NotePropertyName environment -NotePropertyValue ([pscustomobject]@{}) -Force
    }

    $changed = $false
    foreach ($key in $WtEnvKeys.Keys) {
        $existing = $json.profiles.defaults.environment.$key
        if ($Remove) {
            if ($null -ne $existing) {
                $json.profiles.defaults.environment.PSObject.Properties.Remove($key)
                Write-Step "removed profiles.defaults.environment.$key"
                $changed = $true
            } else { Write-Skip "profiles.defaults.environment.$key already absent" }
        } else {
            if ($existing -eq $WtEnvKeys[$key]) { Write-Skip "profiles.defaults.environment.$key already $($WtEnvKeys[$key])" }
            else {
                $json.profiles.defaults.environment | Add-Member -NotePropertyName $key -NotePropertyValue $WtEnvKeys[$key] -Force
                Write-Step "set profiles.defaults.environment.$key = $($WtEnvKeys[$key])"
                $changed = $true
            }
        }
    }

    if (-not $changed) { Write-Ok 'Windows Terminal profile environment already correct'; return }
    if ($DryRun) { Write-Step 'dry run: not writing settings.json'; return }
    Backup-Once $path
    Save-Text $path ($json | ConvertTo-Json -Depth 100)
    Write-Ok 'settings.json updated (Windows Terminal reloads it live; new tabs pick the env up)'
}

# ------------------------------------------------------------------ user env vars
function Set-UserEnv([bool]$Remove) {
    if ($SkipUserEnv) { Write-Skip 'user environment skipped (-SkipUserEnv)'; return }
    foreach ($key in $WtEnvKeys.Keys) {
        $current = [Environment]::GetEnvironmentVariable($key, 'User')
        if ($Remove) {
            if ($null -eq $current) { Write-Skip "$key not set" ; continue }
            if ($DryRun) { Write-Step "would remove user env $key"; continue }
            [Environment]::SetEnvironmentVariable($key, $null, 'User')
            Write-Ok "removed user env $key"
        } else {
            if ($current -eq $WtEnvKeys[$key]) { Write-Skip "user env $key already $current"; continue }
            if ($DryRun) { Write-Step "would set user env $key=$($WtEnvKeys[$key])"; continue }
            [Environment]::SetEnvironmentVariable($key, $WtEnvKeys[$key], 'User')
            Write-Ok "set user env $key=$($WtEnvKeys[$key])"
        }
    }
}

# ---------------------------------------------------------------- omp config.yml
function Set-OmpConfig([bool]$Remove) {
    $path = Join-Path $env:USERPROFILE '.omp\agent\config.yml'
    if (-not (Test-Path -LiteralPath $path)) { Write-Warn2 "omp config not found at $path; run omp once, then re-run this script"; return }
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $path)

    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*showImages\s*:') { $idx = $i; break } }

    if ($Remove) {
        if ($idx -ge 0 -and $lines[$idx] -match 'true') {
            if ($DryRun) { Write-Step 'would remove terminal.showImages'; return }
            $lines.RemoveAt($idx)
            Save-Text $path (($lines -join "`n") + "`n")
            Write-Ok 'removed terminal.showImages'
        } else { Write-Skip 'terminal.showImages not forced by this script' }
        return
    }

    if ($idx -ge 0 -and $lines[$idx] -match 'true') { Write-Skip 'terminal.showImages already true'; return }
    if ($DryRun) { Write-Step 'would set terminal.showImages: true'; return }

    Backup-Once $path
    if ($idx -ge 0) {
        $lines[$idx] = '  showImages: true'
    } else {
        $t = -1
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^terminal\s*:\s*$') { $t = $i; break } }
        if ($t -ge 0) { $lines.Insert($t + 1, '  showImages: true') }
        else { $lines.Add('terminal:'); $lines.Add('  showImages: true') }
    }
    Save-Text $path (($lines -join "`n") + "`n")
    Write-Ok 'set terminal.showImages: true'
}

# ------------------------------------------------------------- PowerShell profiles
function Get-ProfilePaths {
    @(
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

function Clean-Profiles {
    $paths = Get-ProfilePaths
    if (-not $paths) { Write-Skip 'no PowerShell profiles found'; return }
    foreach ($p in $paths) {
        $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $p)
        $hits = @()
        for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\$env:PI_FORCE_IMAGE_PROTOCOL\s*=') { $hits += $i } }
        if ($hits.Count -le 1) { Write-Skip "$([IO.Path]::GetFileName($p)): nothing to collapse ($($hits.Count) line)"; continue }
        if ($DryRun) { Write-Step "would collapse $($hits.Count) duplicate lines in $p"; continue }
        Backup-Once $p
        foreach ($i in ($hits | Select-Object -Skip 1 | Sort-Object -Descending)) { $lines.RemoveAt($i) }
        Save-Text $p (($lines -join "`n") + "`n")
        Write-Ok "$([IO.Path]::GetFileName($p)): collapsed $($hits.Count) duplicate lines into 1"
    }
}

# ------------------------------------------------------------------------ main
Write-Head 'omp-terminal-images'
if ($DryRun) { Write-Warn2 'dry run: nothing will be written' }

$wtVersion = Get-WtVersion
if ($wtVersion) {
    if ($wtVersion -ge [version]'1.22') { Write-Ok "Windows Terminal $wtVersion (SIXEL supported)" }
    else { Write-Warn2 "Windows Terminal $wtVersion is older than 1.22: no SIXEL. Run: winget upgrade Microsoft.WindowsTerminal" }
} else { Write-Warn2 'Windows Terminal package not detected' }

Write-Head 'Windows Terminal profile environment'
Set-WtSettings $Uninstall.IsPresent

Write-Head 'user environment'
Set-UserEnv $Uninstall.IsPresent

Write-Head 'omp settings'
Set-OmpConfig $Uninstall.IsPresent

if ($CleanProfiles -or $Uninstall) {
    Write-Head 'PowerShell profiles'
    Clean-Profiles
}

Write-Head 'next'
if ($Uninstall) {
    Write-Host '  Restart Windows Terminal. Backup files remain as *.bak-ompimages.'
} else {
    Write-Host '  Open a NEW Windows Terminal tab and run:'
    Write-Host '    bun tools/sixel-card.mjs      # should draw a picture'
    Write-Host '    omp                            # then: /terminal-info  ->  Graphics: Sixel'
    Write-Host '  In an existing omp session, images already in the transcript keep their old'
    Write-Host '  text cards until the session is re-rendered (/debug probe or a new session).'
}
