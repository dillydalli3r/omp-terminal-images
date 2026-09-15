<#
.SYNOPSIS
  Unstick an oh-my-pi (omp) that hangs at startup and burns 100% CPU on one core.

.DESCRIPTION
  Two known causes on Windows:

  1. Plugin state mismatch. ~/.omp/plugins/package.json lists a dependency that
     is NOT registered in ~/.omp/plugins/omp-plugins.lock.json (typically a
     plugin built against a different omp fork). omp then spins forever on the
     plugin loader before it creates a session file. Fix: drop the dependency
     entry and move its node_modules directory to quarantine.

  2. Stale terminal breadcrumbs. ~/.omp/agent/terminal-sessions/wt-<guid> holds
     line 1 = cwd, line 2 = session jsonl path, optional line 3 = "fresh".
     If line 2 names a file that no longer exists, a new omp started in that
     terminal can spin. Fix: move the record to quarantine.

  Nothing is ever deleted: files are moved into the quarantine directory, and
  package.json is copied to package.json.bak-ompimages before it is edited.
  Run -Revert to put everything back.

  Safe to run repeatedly: a second run reports only [--] lines and changes nothing.

.PARAMETER DryRun
  Print every intended action without writing or moving anything.

.PARAMETER QuarantineDir
  Where moved files go. Default: $env:USERPROFILE\.omp\.quarantine-ompimages

.PARAMETER SkipBreadcrumbs
  Only handle the plugin state; leave terminal-session records alone.

.PARAMETER Revert
  Restore package.json from its backup and move everything back out of quarantine.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-stuck-startup.ps1 -DryRun

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-stuck-startup.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-stuck-startup.ps1 -Revert
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$QuarantineDir = "$env:USERPROFILE\.omp\.quarantine-ompimages",
    [switch]$SkipBreadcrumbs,
    [switch]$Revert
)

$ErrorActionPreference = 'Continue'

$OmpHome      = Join-Path $env:USERPROFILE '.omp'
$PluginsDir   = Join-Path $OmpHome 'plugins'
$LockFile     = Join-Path $PluginsDir 'omp-plugins.lock.json'
$PkgFile      = Join-Path $PluginsDir 'package.json'
$PkgBackup    = "$PkgFile.bak-ompimages"
$NodeModules  = Join-Path $PluginsDir 'node_modules'
$SessionsDir  = Join-Path $OmpHome 'agent\terminal-sessions'
$QuarPlugins  = Join-Path $QuarantineDir 'plugins'
$QuarSessions = Join-Path $QuarantineDir 'terminal-sessions'

function Say($tag, $msg, $color) { Write-Host ("{0} {1}" -f $tag, $msg) -ForegroundColor $color }
function Ok($m)   { Say '[ok]' $m 'Green' }
function Skip($m) { Say '[--]' $m 'DarkGray' }
function Bad($m)  { Say '[!!]' $m 'Yellow' }
function Detail($m) { Write-Host "     $m" -ForegroundColor Gray }

function EnsureDir($p) {
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# omp's own config files are UTF-8 without BOM; do not add one.
function WriteTextNoBom($path, $text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($path, $text, $enc)
}

function ReadJson($path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) | ConvertFrom-Json } catch { return $null }
}

# Move to a quarantine path; refuse to overwrite an existing quarantined item.
function Quarantine($from, $dst) {
    if (-not (Test-Path -LiteralPath $from)) { return $false }
    if (Test-Path -LiteralPath $dst) {
        Bad "quarantine already holds $(Split-Path -Leaf $dst) - left in place"
        return $false
    }
    EnsureDir (Split-Path -Parent $dst)
    Move-Item -LiteralPath $from -Destination $dst -ErrorAction SilentlyContinue
    return (Test-Path -LiteralPath $dst)
}

# ---------------------------------------------------------------- plugins ----

function Invoke-Plugins {
    if (-not (Test-Path -LiteralPath $LockFile)) {
        Bad "not found: $LockFile - skipping plugin check (omp may not have run yet)"
        return 0
    }
    $lock = ReadJson $LockFile
    if (-not $lock) { Bad "unreadable JSON: $LockFile - skipping plugin check"; return 0 }

    $package = ReadJson $PkgFile
    if (-not $package) { Skip "no readable $PkgFile - nothing to do"; return 0 }
    if (-not $package.dependencies) { Skip 'package.json declares no dependencies'; return 0 }

    $registered = @()
    if ($lock.plugins) { $registered = @($lock.plugins.PSObject.Properties | ForEach-Object { $_.Name }) }

    $stale = @($package.dependencies.PSObject.Properties |
        Where-Object { $registered -notcontains $_.Name } |
        ForEach-Object { $_.Name })

    if ($stale.Count -eq 0) {
        Skip "plugin dependencies already match omp-plugins.lock.json ($($registered.Count) registered)"
        return 0
    }

    if (Test-Path -LiteralPath $PkgBackup) {
        Skip "backup already present: $PkgBackup"
    } elseif ($DryRun) {
        Ok "would back up package.json to $(Split-Path -Leaf $PkgBackup)"
    } else {
        Copy-Item -LiteralPath $PkgFile -Destination $PkgBackup -Force
        Ok "backed up package.json -> $(Split-Path -Leaf $PkgBackup)"
    }

    foreach ($name in $stale) {
        if ($DryRun) {
            Ok "would remove $name"
        } else {
            $package.dependencies.PSObject.Properties.Remove($name)
            Ok "removed $name"
        }
        Detail "not registered in omp-plugins.lock.json"

        $src = Join-Path $NodeModules $name
        $dst = Join-Path $QuarPlugins $name
        if (-not (Test-Path -LiteralPath $src)) {
            Skip "no node_modules\$name on disk"
        } elseif ($DryRun) {
            Ok "would move node_modules\$name -> $dst"
        } elseif (Quarantine $src $dst) {
            Ok "moved node_modules\$name -> $dst"
        }
    }

    if (-not $DryRun) {
        WriteTextNoBom $PkgFile (($package | ConvertTo-Json -Depth 10) + "`n")
    }
    return $stale.Count
}

# ------------------------------------------------------------ breadcrumbs ----

function Invoke-Breadcrumbs {
    if (-not (Test-Path -LiteralPath $SessionsDir)) {
        Skip "not found: $SessionsDir - nothing to do"
        return 0
    }
    $records = @(Get-ChildItem -LiteralPath $SessionsDir -Force -File -ErrorAction SilentlyContinue)
    if ($records.Count -eq 0) { Skip 'no terminal-session records'; return 0 }

    $moved = 0
    $live  = 0
    foreach ($rec in $records) {
        $lines = @(Get-Content -LiteralPath $rec.FullName -ErrorAction SilentlyContinue)
        if ($lines.Count -lt 2 -or [string]::IsNullOrWhiteSpace($lines[1])) {
            Skip "$($rec.Name): no session path on line 2"
            continue
        }
        $session = $lines[1].Trim()
        if (Test-Path -LiteralPath $session) { $live++; continue }

        $dst = Join-Path $QuarSessions $rec.Name
        if ($DryRun) {
            Ok "would move $($rec.Name)"
            Detail "missing session: $session"
            $moved++
        } elseif (Quarantine $rec.FullName $dst) {
            Ok "moved $($rec.Name)"
            Detail "missing session: $session"
            $moved++
        }
    }

    if ($moved -eq 0) { Skip "no stale records ($live live)" }
    else { Ok "$moved stale record(s) quarantined -> $QuarSessions" }
    return $moved
}

# ----------------------------------------------------------------- revert ----

function Restore-Dir($from, $to, $label) {
    if (Test-Path -LiteralPath $to) { Bad "node_modules\$label already exists - left in quarantine"; return }
    if ($DryRun) { Ok "would restore node_modules\$label"; return }
    EnsureDir (Split-Path -Parent $to)
    Move-Item -LiteralPath $from -Destination $to -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $to) { Ok "restored node_modules\$label" } else { Bad "could not restore node_modules\$label" }
}

function Invoke-Revert {
    if (Test-Path -LiteralPath $PkgBackup) {
        if ($DryRun) {
            Ok "would restore package.json from $(Split-Path -Leaf $PkgBackup)"
        } else {
            Copy-Item -LiteralPath $PkgBackup -Destination $PkgFile -Force
            Ok "restored package.json from $(Split-Path -Leaf $PkgBackup)"
        }
    } else {
        Bad "no backup at $PkgBackup - package.json left as is"
    }

    if (Test-Path -LiteralPath $QuarPlugins) {
        foreach ($item in @(Get-ChildItem -LiteralPath $QuarPlugins -Force)) {
            if (-not $item.PSIsContainer) { Skip "not a package directory: $($item.Name)"; continue }
            if ($item.Name.StartsWith('@')) {
                # scope directory: restore each package inside it
                foreach ($sub in @(Get-ChildItem -LiteralPath $item.FullName -Force -Directory)) {
                    Restore-Dir $sub.FullName (Join-Path $NodeModules "$($item.Name)\$($sub.Name)") "$($item.Name)/$($sub.Name)"
                }
                if (-not $DryRun -and @(Get-ChildItem -LiteralPath $item.FullName -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $item.FullName -Force
                }
            } else {
                Restore-Dir $item.FullName (Join-Path $NodeModules $item.Name) $item.Name
            }
        }
    } else {
        Skip "nothing quarantined at $QuarPlugins"
    }

    if (Test-Path -LiteralPath $QuarSessions) {
        $back = 0
        foreach ($rec in @(Get-ChildItem -LiteralPath $QuarSessions -Force -File)) {
            $dst = Join-Path $SessionsDir $rec.Name
            if ($DryRun) { Ok "would restore terminal-session $($rec.Name)"; $back++; continue }
            if (Test-Path -LiteralPath $dst) { Bad "already present: $($rec.Name)"; continue }
            EnsureDir $SessionsDir
            Move-Item -LiteralPath $rec.FullName -Destination $dst -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dst) { $back++; Ok "restored terminal-session $($rec.Name)" }
            else { Bad "could not restore $($rec.Name)" }
        }
        if ($back -eq 0) { Skip 'no quarantined terminal-session records' }
    } else {
        Skip "nothing quarantined at $QuarSessions"
    }
}

# ------------------------------------------------------------------ main ----

Write-Host ''
Write-Host "== omp stuck-startup fix" -ForegroundColor Cyan
Write-Host "   omp home:   $OmpHome"
Write-Host "   quarantine: $QuarantineDir"
if ($DryRun) { Write-Host '   mode:       DRY RUN (nothing will be changed)' -ForegroundColor Yellow }

if ($Revert) {
    Write-Host "`n-- revert" -ForegroundColor Cyan
    Invoke-Revert
    Write-Host "`n== summary" -ForegroundColor Cyan
    Write-Host '   Quarantine contents were moved back. package.json restored from backup.'
    Write-Host '   Open a new terminal and run omp.'
    Write-Host ''
    exit 0
}

Write-Host "`n-- plugins" -ForegroundColor Cyan
$pluginCount = Invoke-Plugins

Write-Host "`n-- terminal-session breadcrumbs" -ForegroundColor Cyan
if ($SkipBreadcrumbs) { Skip 'skipped (-SkipBreadcrumbs)' ; $breadcrumbCount = 0 }
else { $breadcrumbCount = Invoke-Breadcrumbs }

Write-Host "`n== summary" -ForegroundColor Cyan
Write-Host ("   plugin dependencies unregistered: {0}" -f $pluginCount)
Write-Host ("   stale terminal-session records:   {0}" -f $breadcrumbCount)
if ($DryRun) {
    Write-Host '   Dry run finished - nothing was written or moved. Re-run without -DryRun to apply.' -ForegroundColor Yellow
} else {
    Write-Host "   Quarantined files (nothing deleted): $QuarantineDir" -ForegroundColor Gray
    Write-Host '   Next: open a NEW terminal tab and run omp.' -ForegroundColor Green
    Write-Host '   Undo: powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-stuck-startup.ps1 -Revert' -ForegroundColor Gray
}
Write-Host ''
exit 0
