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
  Run -Revert to put everything back; -Revert moves the backup over package.json
  (so it leaves no .bak-ompimages behind) and drops the quarantine tree once it
  is empty.

  Every move that fails is reported and counted - a locked file is never silent.
  The exit code is that failure count, so a runner can gate on it.

  package.json is edited as text: the dependency entry is deleted in place, so
  key order, indentation and line endings survive (a ConvertTo-Json round trip
  would rewrite the whole file). The result is re-parsed before it is written,
  and the backup is restored if it does not parse.

  Safe to run repeatedly: a second run reports only [--] lines and changes nothing.

.PARAMETER DryRun
  Print every intended action without writing or moving anything.

.PARAMETER QuarantineDir
  Where moved files go. Default: $env:USERPROFILE\.omp\.quarantine-ompimages

.PARAMETER SkipBreadcrumbs
  Only handle the plugin state; leave terminal-session records alone.

.PARAMETER Revert
  Restore package.json from its backup (the backup is moved, not copied) and
  move everything back out of quarantine. Reports an exact conflict - file and
  both paths - when the destination already exists, instead of leaving the item
  quarantined silently.

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

$script:Failures = 0

function Say($tag, $msg, $color) { Write-Host ("{0} {1}" -f $tag, $msg) -ForegroundColor $color }
function Ok($m)   { Say '[ok]' $m 'Green' }
function Skip($m) { Say '[--]' $m 'DarkGray' }
function Bad($m)  { Say '[!!]' $m 'Yellow' }
function Fail($m) { $script:Failures++; Say '[!!]' $m 'Yellow' }
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

# ------------------------------------------------- JSON text surgery (as in install.ps1) ----
# package.json is rewritten with a targeted text splice so its key order,
# indentation and line endings survive.

function Skip-JsonString([string]$T, [int]$Pos, [int]$End) {
    $i = $Pos + 1
    while ($i -lt $End) {
        $c = $T[$i]
        if ($c -eq '\') { $i += 2; continue }
        if ($c -eq '"') { return $i + 1 }
        $i++
    }
    return $End
}

function Skip-JsonGap([string]$T, [int]$Pos, [int]$End) {
    $i = $Pos
    while ($i -lt $End) {
        $c = $T[$i]
        if ([char]::IsWhiteSpace($c)) { $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $End -and $T[$i + 1] -eq '/') {
            while ($i -lt $End -and $T[$i] -ne "`n") { $i++ }
            continue
        }
        if ($c -eq '/' -and $i + 1 -lt $End -and $T[$i + 1] -eq '*') {
            $i += 2
            while ($i + 1 -lt $End -and -not ($T[$i] -eq '*' -and $T[$i + 1] -eq '/')) { $i++ }
            $i += 2
            continue
        }
        break
    }
    return $i
}

function Match-JsonClose([string]$T, [int]$Pos, [int]$End) {
    $openCh = $T[$Pos]
    $closeCh = if ($openCh -eq '{') { '}' } else { ']' }
    $depth = 0
    $i = $Pos
    while ($i -lt $End) {
        $c = $T[$i]
        if ($c -eq '"') { $i = Skip-JsonString $T $i $End; continue }
        if ($c -eq '/' -and $i + 1 -lt $End -and $T[$i + 1] -eq '/') { while ($i -lt $End -and $T[$i] -ne "`n") { $i++ }; continue }
        if ($c -eq '/' -and $i + 1 -lt $End -and $T[$i + 1] -eq '*') { $i += 2; while ($i + 1 -lt $End -and -not ($T[$i] -eq '*' -and $T[$i + 1] -eq '/')) { $i++ }; $i += 2; continue }
        if ($c -eq $openCh) { $depth++ }
        elseif ($c -eq $closeCh) { $depth--; if ($depth -eq 0) { return $i } }
        $i++
    }
    return -1
}

function Skip-JsonValue([string]$T, [int]$Pos, [int]$End) {
    if ($Pos -ge $End) { return $End }
    $c = $T[$Pos]
    if ($c -eq '"') { return Skip-JsonString $T $Pos $End }
    if ($c -eq '{' -or $c -eq '[') {
        $j = Match-JsonClose $T $Pos $End
        if ($j -lt 0) { return $End }
        return $j + 1
    }
    $i = $Pos
    while ($i -lt $End) {
        $c = $T[$i]
        if ($c -eq ',' -or $c -eq '}' -or $c -eq ']' -or [char]::IsWhiteSpace($c)) { break }
        $i++
    }
    return $i
}

function Get-JsonMembers([string]$T, [int]$Open, [int]$Close) {
    $list = @()
    $i = $Open + 1
    while ($i -lt $Close) {
        $i = Skip-JsonGap $T $i $Close
        if ($i -ge $Close) { break }
        if ($T[$i] -eq ',') { $i++; continue }
        if ($T[$i] -ne '"') { $i++; continue }
        $ks = $i
        $i = Skip-JsonString $T $i $Close
        $key = $T.Substring($ks, $i - $ks)
        $j = Skip-JsonGap $T $i $Close
        if ($j -lt $Close -and $T[$j] -eq ':') {
            $vs = Skip-JsonGap $T ($j + 1) $Close
            $ve = Skip-JsonValue $T $vs $Close
            $list += @{ Key = $key; KeyStart = $ks; ValStart = $vs; ValEnd = $ve }
            $i = $ve
        }
    }
    return $list
}

function Find-JsonProp([string]$T, [int]$Open, [int]$Close, [string]$Name) {
    foreach ($p in @(Get-JsonMembers $T $Open $Close)) {
        if ($p.Key -eq ('"' + $Name + '"')) { return $p }
    }
    return $null
}

# Edit that deletes property $Prop, taking its line and its comma with it.
function New-RemoveEdit([string]$T, $Prop, [int]$Open, [int]$Close) {
    $k = Skip-JsonGap $T $Prop.ValEnd $Close
    $hasComma = ($k -lt $Close -and $T[$k] -eq ',')

    $lineStart = $Prop.KeyStart
    while ($lineStart -gt $Open + 1 -and $T[$lineStart - 1] -ne "`n") { $lineStart-- }
    $ownLine = $true
    for ($i = $lineStart; $i -lt $Prop.KeyStart; $i++) {
        if (-not [char]::IsWhiteSpace($T[$i])) { $ownLine = $false; break }
    }

    if (-not $ownLine) {
        if ($hasComma) { return @{ Start = $Prop.KeyStart; End = $k + 1; Text = '' } }
        $p = $Prop.KeyStart
        while ($p -gt $Open + 1 -and ($T[$p - 1] -eq ' ' -or $T[$p - 1] -eq "`t")) { $p-- }
        $start = if ($p -gt $Open + 1 -and $T[$p - 1] -eq ',') { $p - 1 } else { $Prop.KeyStart }
        return @{ Start = $start; End = $Prop.ValEnd; Text = '' }
    }

    $end = if ($hasComma) { $k + 1 } else { $Prop.ValEnd }
    $after = $end
    while ($after -lt $T.Length -and ($T[$after] -eq ' ' -or $T[$after] -eq "`t" -or $T[$after] -eq "`r")) { $after++ }
    $blankTail = ($after -lt $T.Length -and $T[$after] -eq "`n")
    if ($hasComma) {
        if ($blankTail) { $end = $after + 1 }
        return @{ Start = $lineStart; End = $end; Text = '' }
    }

    $p = $lineStart
    while ($p -gt $Open + 1 -and [char]::IsWhiteSpace($T[$p - 1])) { $p-- }
    $start = if ($p -gt $Open + 1 -and $T[$p - 1] -eq ',') { $p - 1 } else { $lineStart }
    if ($blankTail -and $start -eq $lineStart) { $end = $after + 1 }
    return @{ Start = $start; End = $end; Text = '' }
}

function Apply-Edits([string]$T, $Edits) {
    foreach ($e in ($Edits | Sort-Object -Property Start -Descending)) {
        $T = $T.Substring(0, $e.Start) + $e.Text + $T.Substring($e.End)
    }
    return $T
}

# Drop $Name from the "dependencies" object of package.json, in place.
# Returns the new text, or $null when the file could not be edited safely.
function Remove-Dependency([string]$Text, [string]$Name) {
    $rootOpen = Skip-JsonGap $Text 0 $Text.Length
    if ($rootOpen -ge $Text.Length -or $Text[$rootOpen] -ne '{') { return $null }
    $rootClose = Match-JsonClose $Text $rootOpen $Text.Length
    if ($rootClose -lt 0) { return $null }
    $deps = Find-JsonProp $Text $rootOpen $rootClose 'dependencies'
    if (-not $deps -or $Text[$deps.ValStart] -ne '{') { return $null }
    $depsClose = Match-JsonClose $Text $deps.ValStart $Text.Length
    if ($depsClose -lt 0) { return $null }
    $prop = Find-JsonProp $Text $deps.ValStart $depsClose $Name
    if (-not $prop) { return $null }
    return Apply-Edits $Text @((New-RemoveEdit $Text $prop $deps.ValStart $depsClose))
}

# Move to a quarantine path; refuse to overwrite an existing quarantined item.
function Quarantine($from, $dst) {
    if (-not (Test-Path -LiteralPath $from)) { return $false }
    if (Test-Path -LiteralPath $dst) {
        Fail "quarantine already holds $(Split-Path -Leaf $dst) - left in place at $from"
        return $false
    }
    EnsureDir (Split-Path -Parent $dst)
    try {
        Move-Item -LiteralPath $from -Destination $dst -ErrorAction Stop
    } catch {
        Fail "could not move $from -> $dst : $($_.Exception.Message)"
        return $false
    }
    if (-not (Test-Path -LiteralPath $dst)) { Fail "move of $from produced nothing at $dst"; return $false }
    if (Test-Path -LiteralPath $from) { Fail "$from is still there after moving it"; return $false }
    return $true
}

# Move $from back to $to, reporting a precise conflict instead of giving up quietly.
function Move-Back($from, $to, $label) {
    if (Test-Path -LiteralPath $to) {
        Fail "conflict: $to already exists - $label stays quarantined at $from (merge or delete one of them, then re-run -Revert)"
        return $false
    }
    if ($DryRun) { Ok "would restore $label"; return $true }
    EnsureDir (Split-Path -Parent $to)
    try {
        Move-Item -LiteralPath $from -Destination $to -ErrorAction Stop
    } catch {
        Fail "could not restore $label ($from -> $to) : $($_.Exception.Message)"
        return $false
    }
    Ok "restored $label"
    return $true
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
        Copy-Item -LiteralPath $PkgFile -Destination $PkgBackup
        Ok "backed up package.json -> $(Split-Path -Leaf $PkgBackup)"
    }

    $text = Get-Content -LiteralPath $PkgFile -Raw
    $removed = @()
    foreach ($name in $stale) {
        if ($DryRun) {
            Ok "would remove $name"
            Detail "not registered in omp-plugins.lock.json"
            $removed += $name
        } else {
            $edited = Remove-Dependency $text $name
            if (-not $edited) {
                Fail "could not delete the '$name' entry from package.json (unexpected layout) - file left untouched"
            } else {
                $text = $edited
                $removed += $name
                Ok "removed $name"
                Detail "not registered in omp-plugins.lock.json"
            }
        }

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

    if (-not $DryRun -and $removed.Count -gt 0) {
        $check = $null
        try { $check = $text | ConvertFrom-Json } catch { $check = $null }
        if (-not $check) {
            Fail 'the edited package.json does not parse - restoring the backup'
            if (Test-Path -LiteralPath $PkgBackup) { Copy-Item -LiteralPath $PkgBackup -Destination $PkgFile -Force }
            return 0
        }
        WriteTextNoBom $PkgFile $text
    }
    return $removed.Count
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

function Remove-IfEmpty($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    if (@(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $path)) { Detail "removed empty $path" }
    }
}

function Invoke-Revert {
    if (Test-Path -LiteralPath $PkgBackup) {
        if ($DryRun) {
            Ok "would move $(Split-Path -Leaf $PkgBackup) back over package.json"
        } else {
            try {
                Move-Item -LiteralPath $PkgBackup -Destination $PkgFile -Force -ErrorAction Stop
                Ok "restored package.json from $(Split-Path -Leaf $PkgBackup) (backup moved back, none left behind)"
            } catch {
                Fail "could not restore package.json from $PkgBackup : $($_.Exception.Message)"
            }
        }
    } else {
        Fail "no backup at $PkgBackup - package.json left as is"
    }

    if (Test-Path -LiteralPath $QuarPlugins) {
        foreach ($item in @(Get-ChildItem -LiteralPath $QuarPlugins -Force)) {
            if (-not $item.PSIsContainer) { Skip "not a package directory: $($item.Name)"; continue }
            if ($item.Name.StartsWith('@')) {
                # scope directory: restore each package inside it
                foreach ($sub in @(Get-ChildItem -LiteralPath $item.FullName -Force -Directory)) {
                    Move-Back $sub.FullName (Join-Path $NodeModules "$($item.Name)\$($sub.Name)") "node_modules/$($item.Name)/$($sub.Name)"
                }
                Remove-IfEmpty $item.FullName
            } else {
                Move-Back $item.FullName (Join-Path $NodeModules $item.Name) "node_modules\$($item.Name)"
            }
        }
        Remove-IfEmpty $QuarPlugins
    } else {
        Skip "nothing quarantined at $QuarPlugins"
    }

    if (Test-Path -LiteralPath $QuarSessions) {
        $back = 0
        $total = @(Get-ChildItem -LiteralPath $QuarSessions -Force -File).Count
        foreach ($rec in @(Get-ChildItem -LiteralPath $QuarSessions -Force -File)) {
            if (Move-Back $rec.FullName (Join-Path $SessionsDir $rec.Name) "terminal-session $($rec.Name)") { $back++ }
        }
        if ($total -eq 0) { Skip 'no quarantined terminal-session records' }
        Remove-IfEmpty $QuarSessions
    } else {
        Skip "nothing quarantined at $QuarSessions"
    }

    Remove-IfEmpty $QuarantineDir
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
    Write-Host ("   failures: {0}" -f $script:Failures)
    if ($script:Failures -eq 0) {
        Write-Host '   Quarantine contents were moved back. package.json restored from the backup.'
        Write-Host '   Open a new terminal and run omp.'
    } else {
        Write-Host '   Some items could not be put back - see the [!!] lines above.' -ForegroundColor Yellow
    }
    Write-Host ("   exit code {0}" -f $script:Failures)
    Write-Host ''
    exit $script:Failures
}

Write-Host "`n-- plugins" -ForegroundColor Cyan
$pluginCount = Invoke-Plugins

Write-Host "`n-- terminal-session breadcrumbs" -ForegroundColor Cyan
if ($SkipBreadcrumbs) { Skip 'skipped (-SkipBreadcrumbs)' ; $breadcrumbCount = 0 }
else { $breadcrumbCount = Invoke-Breadcrumbs }

Write-Host "`n== summary" -ForegroundColor Cyan
Write-Host ("   plugin dependencies unregistered: {0}" -f $pluginCount)
Write-Host ("   stale terminal-session records:   {0}" -f $breadcrumbCount)
Write-Host ("   failures:                         {0}" -f $script:Failures)
if ($DryRun) {
    Write-Host '   Dry run finished - nothing was written or moved. Re-run without -DryRun to apply.' -ForegroundColor Yellow
} else {
    Write-Host "   Quarantined files (nothing deleted): $QuarantineDir" -ForegroundColor Gray
    Write-Host '   Next: open a NEW terminal tab and run omp.' -ForegroundColor Green
    Write-Host '   Undo: powershell -NoProfile -ExecutionPolicy Bypass -File .\fix-stuck-startup.ps1 -Revert' -ForegroundColor Gray
}
Write-Host ("   exit code {0}" -f $script:Failures)
Write-Host ''
exit $script:Failures
