<#
.SYNOPSIS
  Make oh-my-pi (omp) render inline images on Windows Terminal.

.DESCRIPTION
  Pins PI_FORCE_IMAGE_PROTOCOL=sixel for Windows Terminal sessions (WT never
  answers omp's XTSMGRAPHICS capability probe, so automatic detection leaves
  images as "[Image: ...]" text cards), enables OSC 8 hyperlinks so image chips
  are clickable, and makes sure omp's terminal.showImages setting is on.

  Idempotent, and loud: every step prints [ok]/[--]/[!!] and the process exit
  code is the number of failed steps, so an unattended runner can gate on it.
  The bundle patch is a required step: if it does not land, the install fails.

  Uninstall manifest. On the first run the script records every value it is
  about to overwrite in ~/.omp/.ompimages-manifest.json - the WT profile
  environment values as they were (including their absence), the user-level
  environment values, the prior `showImages` line (or its absence), and the path
  + sha256 of every file it edits. -Uninstall puts those values back and deletes
  the manifest. The manifest is written once and never overwritten, so the
  recorded priors are always the pristine ones.

  Files are edited in place as text, so comments, line endings and the trailing
  newline survive; settings.json is never round-tripped through ConvertFrom-Json
  and never re-formatted. Backups ("<file>.bak-ompimages") are create-once too.

  Requires Windows Terminal >= 1.22 for SIXEL rendering.

.PARAMETER Uninstall
  Restore every change recorded in the manifest and remove the manifest. If no
  manifest exists there is nothing to restore from, and the script says so and
  exits non-zero.

.PARAMETER DryRun
  Print what would change without writing anything (no writes, no network).

.PARAMETER Json
  Print exactly one machine-readable JSON result object on stdout and nothing
  else. Fields: ok, exitCode, failures, dryRun, uninstall, manifestPath,
  manifestWritten, steps[] ({step,status,detail}, status is ok|changed|skip|
  fail), patcher{} (the raw tool/patch-paste-images.mjs `check --json` object).

.PARAMETER CleanProfiles
  Collapse duplicated "$env:PI_FORCE_IMAGE_PROTOCOL = 'sixel'" lines left in
  PowerShell profiles down to one.

.PARAMETER SkipUserEnv
  Do not touch the user-level environment variables (WT profile env only).

.EXAMPLE
  pwsh -File install.ps1 -DryRun -Json     # preview, machine readable, writes nothing

.EXAMPLE
  pwsh -File install.ps1                   # install; exit code = failed step count

.EXAMPLE
  pwsh -File install.ps1 -Uninstall        # restore the manifest and delete it

.NOTES
  Also patches the pasted-image surfaces (composer attachment card + transcript entry),
  which omp only draws for Kitty terminals. That patch edits the vendored, minified
  dist/cli.js of @oh-my-pi/pi-coding-agent, keeps a backup next to it, and has to be
  re-applied after every omp upgrade; -Uninstall reverts it.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$Json,
    [switch]$CleanProfiles,
    [switch]$SkipUserEnv
)

$ErrorActionPreference = 'Stop'

$ProtocolValue = 'sixel'
$HyperlinkValue = '1'
$BackupSuffix = '.bak-ompimages'
$ManifestPath = Join-Path $env:USERPROFILE '.omp\.ompimages-manifest.json'
$WtEnvKeys = [ordered]@{
    'PI_FORCE_IMAGE_PROTOCOL' = $ProtocolValue
    'PI_FORCE_HYPERLINKS'     = $HyperlinkValue
}

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:ManifestWritten = $false

# Everything below prints through these, and every one of them is silent in -Json
# mode so stdout carries exactly one JSON object.
function Write-Step($msg) { if (-not $Json) { Write-Host "  $msg" } }
function Write-Head($msg) { if (-not $Json) { Write-Host "`n== $msg" -ForegroundColor Cyan } }
function Write-Skip($msg) { if (-not $Json) { Write-Host "  [--] $msg" -ForegroundColor DarkGray } }
function Write-Warn2($msg) { if (-not $Json) { Write-Host "  [!!] $msg" -ForegroundColor Yellow } }

function Add-Result([string]$Step, [string]$Status, [string]$Detail) {
    $script:Results.Add([pscustomobject]@{ step = $Step; status = $Status; detail = $Detail })
}
function Say-Changed($step, $detail) { if (-not $Json) { Write-Host "  [ok] $detail" -ForegroundColor Green }; Add-Result $step 'changed' $detail }
function Say-Ok($step, $detail)      { Write-Skip $detail; Add-Result $step 'ok' $detail }
function Say-Skip($step, $detail)    { Write-Skip $detail; Add-Result $step 'skip' $detail }
function Say-Fail($step, $detail)    { Write-Warn2 $detail; Add-Result $step 'fail' $detail }

# ----------------------------------------------------------------- manifest ----

$script:Man = [ordered]@{
    version       = 1
    createdAt     = (Get-Date).ToUniversalTime().ToString('o')
    wtSettingsPath = $null
    wtEnv         = [ordered]@{}
    userEnv       = [ordered]@{}
    ompConfigPath = $null
    showImagesLine = $null
    files         = @()
    bundle        = [ordered]@{ cliPath = $null; sha256 = $null; ompVersion = $null }
}

function Get-Sha256([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

function Add-FileRecord([string]$Path) {
    if (-not $Path) { return }
    $script:Man.files += [ordered]@{ path = $Path; sha256 = Get-Sha256 $Path }
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }
    try { return (Get-Content -LiteralPath $ManifestPath -Raw) | ConvertFrom-Json } catch { return $null }
}

# Create-once: a second install must not overwrite the pristine priors.
function Save-Manifest {
    if ($DryRun) { return }
    if (Test-Path -LiteralPath $ManifestPath) { Write-Skip "manifest already recorded: $ManifestPath"; return }
    $dir = Split-Path -Parent $ManifestPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($ManifestPath, ($script:Man | ConvertTo-Json -Depth 8) + "`n", $enc)
    $script:ManifestWritten = $true
    Write-Step "manifest -> $ManifestPath"
}

function Get-ManValue($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties.Name -notcontains $Name) { return $null }
    return $Obj.$Name
}

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
    if (Test-Path -LiteralPath $backup) { Write-Skip "backup already present: $backup"; return }
    if ($DryRun) { Write-Step "would back up $Path -> $backup"; return }
    Copy-Item -LiteralPath $Path -Destination $backup
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

# ------------------------------------------------------- JSONC text surgery ----
# settings.json is JSON with comments. Every edit is a targeted text splice, so
# the rest of the file keeps its comments, indentation and line endings.

# Index just past the closing quote of the string that starts at $Pos.
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

# Index of the next token after whitespace and // and /* */ comments.
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

# Index of the '}'/']' matching the '{'/'[' at $Pos, or -1.
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

# Index just past the value that starts at $Pos.
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

# Every property of the object [$Open,$Close] in order: @{Key;KeyStart;ValStart;ValEnd}.
function Get-JsonMembers([string]$T, [int]$Open, [int]$Close) {
    $list = @()
    $i = $Open + 1
    while ($i -lt $Close) {
        $i = Skip-JsonGap $T $i $Close
        if ($i -ge $Close) { break }
        if ($T[$i] -eq ',') { $i++; continue }          # JSONC allows trailing commas
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

# First property named $Name at the top level of the object [$Open,$Close], or $null.
function Find-JsonProp([string]$T, [int]$Open, [int]$Close, [string]$Name) {
    foreach ($p in @(Get-JsonMembers $T $Open $Close)) {
        if ($p.Key -eq ('"' + $Name + '"')) { return $p }
    }
    return $null
}

# Indentation of the line that contains $Pos.
function Get-LineIndent([string]$T, [int]$Pos) {
    $s = $Pos
    while ($s -gt 0 -and $T[$s - 1] -ne "`n") { $s-- }
    $indent = ''
    while ($s -lt $Pos -and ($T[$s] -eq ' ' -or $T[$s] -eq "`t")) { $indent += $T[$s]; $s++ }
    return $indent
}

# Edit that appends $Member as the last member of the object [$Open,$Close].
# ponytail: nested members are indented in 4-space steps like WT's own writer.
function New-MemberEdit([string]$T, [int]$Open, [int]$Close, [string]$Member, [string]$Eol) {
    $closeIndent = Get-LineIndent $T $Close
    $memberIndent = $closeIndent + '    '
    $members = @(Get-JsonMembers $T $Open $Close)
    if ($members.Count -eq 0) {
        return @{ Start = $Open + 1; End = $Close; Text = $Eol + $memberIndent + $Member + $Eol + $closeIndent }
    }
    $last = $members[$members.Count - 1]
    $comma = $false
    for ($k = $last.ValEnd; $k -lt $Close; $k++) { if ($T[$k] -eq ',') { $comma = $true; break } }
    $tail = $Eol + $memberIndent + $Member + $Eol + $closeIndent
    if ($comma) {
        $ws = $Close
        while ($ws -gt $last.ValEnd -and [char]::IsWhiteSpace($T[$ws - 1])) { $ws-- }
        return @{ Start = $ws; End = $Close; Text = $tail }
    }
    # The gap between the last value and '}' can hold a // comment; the comma has to
    # land before it, so splice from the value's end and re-emit the gap verbatim.
    $ws = $Close
    while ($ws -gt $last.ValEnd -and [char]::IsWhiteSpace($T[$ws - 1])) { $ws-- }
    return @{ Start = $last.ValEnd; End = $Close; Text = ',' + $T.Substring($last.ValEnd, $ws - $last.ValEnd) + $tail }
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
        # Inline member: take the member plus whichever comma belongs to it.
        if ($hasComma) { return @{ Start = $Prop.KeyStart; End = $k + 1; Text = '' } }
        $p = $Prop.KeyStart
        while ($p -gt $Open + 1 -and ($T[$p - 1] -eq ' ' -or $T[$p - 1] -eq "`t")) { $p-- }
        $start = if ($p -gt $Open + 1 -and $T[$p - 1] -eq ',') { $p - 1 } else { $Prop.KeyStart }
        return @{ Start = $start; End = $Prop.ValEnd; Text = '' }
    }

    $end = if ($hasComma) { $k + 1 } else { $Prop.ValEnd }
    # Nothing but whitespace after the member on its line -> the whole line goes.
    $after = $end
    while ($after -lt $T.Length -and ($T[$after] -eq ' ' -or $T[$after] -eq "`t" -or $T[$after] -eq "`r")) { $after++ }
    $blankTail = ($after -lt $T.Length -and $T[$after] -eq "`n")
    if ($hasComma) {
        if ($blankTail) { $end = $after + 1 }
        return @{ Start = $lineStart; End = $end; Text = '' }
    }

    # Last member: take the comma that separated it from the previous one too. That
    # comma sits at the end of the previous line, so the line break it swallows is
    # the one this member's line used to own -- do not also take the trailing one.
    $p = $lineStart
    while ($p -gt $Open + 1 -and [char]::IsWhiteSpace($T[$p - 1])) { $p-- }
    $start = if ($p -gt $Open + 1 -and $T[$p - 1] -eq ',') { $p - 1 } else { $lineStart }
    if ($blankTail -and $start -eq $lineStart) { $end = $after + 1 }
    return @{ Start = $start; End = $end; Text = '' }
}

# Right-to-left so earlier offsets stay valid; callers must not nest edits.
function Apply-Edits([string]$T, $Edits) {
    foreach ($e in ($Edits | Sort-Object -Property Start -Descending)) {
        $T = $T.Substring(0, $e.Start) + $e.Text + $T.Substring($e.End)
    }
    return $T
}

function New-JsonObjectText([string[]]$Members, [string]$MemberIndent, [string]$Eol) {
    $closeIndent = if ($MemberIndent.Length -ge 4) { $MemberIndent.Substring(0, $MemberIndent.Length - 4) } else { '' }
    if ($Members.Count -eq 0) { return '{}' }
    return '{' + $Eol + (($Members | ForEach-Object { $MemberIndent + $_ }) -join (',' + $Eol)) + $Eol + $closeIndent + '}'
}

# Value literal of a property, unquoted; $null when the property does not exist.
function Get-PropText([string]$T, $Prop) {
    if (-not $Prop) { return $null }
    $raw = $T.Substring($Prop.ValStart, $Prop.ValEnd - $Prop.ValStart)
    if ($raw.Length -ge 2 -and $raw.StartsWith('"') -and $raw.EndsWith('"')) { return $raw.Substring(1, $raw.Length - 2) }
    return $raw
}

# ------------------------------------------------------- profiles.defaults ----
# Resolve profiles.defaults.environment. With -Create the missing chain is
# inserted first (then resolved again); without it a missing chain reports
# Absent, which -Uninstall treats as "nothing to put back".
function Resolve-WtEnvObject([string]$Text, [string]$Eol, [bool]$Create) {
    $rootOpen = Skip-JsonGap $Text 0 $Text.Length
    if ($rootOpen -ge $Text.Length -or $Text[$rootOpen] -ne '{') { return @{ Ok = $false; Error = 'settings.json is not a JSON object' } }
    $rootClose = Match-JsonClose $Text $rootOpen $Text.Length
    if ($rootClose -lt 0) { return @{ Ok = $false; Error = 'settings.json has unbalanced braces' } }

    $prof = Find-JsonProp $Text $rootOpen $rootClose 'profiles'
    if ($prof -and $Text[$prof.ValStart] -eq '[') {
        return @{ Ok = $false; Error = 'settings.json writes "profiles" as an array; this script only edits the object form {"profiles":{"defaults":{"environment":{"PI_FORCE_IMAGE_PROTOCOL":"sixel"}}}}. Set the two variables in Windows Terminal settings (Profiles > Defaults > Environment), or convert profiles to the object form, then re-run.' }
    }
    if ($prof -and $Text[$prof.ValStart] -ne '{') { return @{ Ok = $false; Error = '"profiles" is not an object' } }

    $keyLines = @($WtEnvKeys.Keys | ForEach-Object { '"{0}": "{1}"' -f $_, $WtEnvKeys[$_] })

    if (-not $prof) {
        if (-not $Create) { return @{ Ok = $false; Absent = $true } }
        $m = (Get-LineIndent $Text $rootClose) + '    '
        $frag = '"profiles": ' + (New-JsonObjectText @('"defaults": ' + (New-JsonObjectText @('"environment": ' + (New-JsonObjectText $keyLines ($m + '            ') $Eol)) ($m + '        ') $Eol)) ($m + '    ') $Eol)
        $Text = Apply-Edits $Text @((New-MemberEdit $Text $rootOpen $rootClose $frag $Eol))
        return Resolve-WtEnvObject $Text $Eol $false
    }

    $profOpen = $prof.ValStart
    $profClose = Match-JsonClose $Text $profOpen $Text.Length
    $defs = Find-JsonProp $Text $profOpen $profClose 'defaults'
    if ($defs -and $Text[$defs.ValStart] -ne '{') { return @{ Ok = $false; Error = 'profiles.defaults is not an object' } }

    if (-not $defs) {
        if (-not $Create) { return @{ Ok = $false; Absent = $true } }
        $m = (Get-LineIndent $Text $profClose) + '    '
        $frag = '"defaults": ' + (New-JsonObjectText @('"environment": ' + (New-JsonObjectText $keyLines ($m + '        ') $Eol)) ($m + '    ') $Eol)
        $Text = Apply-Edits $Text @((New-MemberEdit $Text $profOpen $profClose $frag $Eol))
        return Resolve-WtEnvObject $Text $Eol $false
    }

    $defsOpen = $defs.ValStart
    $defsClose = Match-JsonClose $Text $defsOpen $Text.Length
    $env = Find-JsonProp $Text $defsOpen $defsClose 'environment'
    if ($env -and $Text[$env.ValStart] -ne '{') { return @{ Ok = $false; Error = 'profiles.defaults.environment is not an object' } }

    if (-not $env) {
        if (-not $Create) { return @{ Ok = $false; Absent = $true } }
        $m = (Get-LineIndent $Text $defsClose) + '    '
        $frag = '"environment": ' + (New-JsonObjectText $keyLines ($m + '    ') $Eol)
        $Text = Apply-Edits $Text @((New-MemberEdit $Text $defsOpen $defsClose $frag $Eol))
        return Resolve-WtEnvObject $Text $Eol $false
    }

    return @{ Ok = $true; Text = $Text; Open = $env.ValStart; Close = (Match-JsonClose $Text $env.ValStart $Text.Length); Env = $env }
}

# ---------------------------------------------------------------- settings.json
function Set-WtSettings([bool]$Remove) {
    $step = 'wt-profile-env'
    $path = Get-WtSettingsPath
    if (-not $path) { Say-Fail $step 'Windows Terminal settings.json not found; the profile environment cannot be set'; return }
    Write-Step "settings.json: $path"

    $man = if ($Remove) { Read-Manifest } else { $script:Man }
    $text = Get-Content -LiteralPath $path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) { Say-Fail $step "settings.json is empty: $path"; return }
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if (-not $Remove) { $script:Man.wtSettingsPath = $path }

    # -Uninstall: a file still byte-identical to the pre-install hash was never
    # changed by us, so there is nothing to put back.
    if ($Remove) {
        if (-not (Get-ManValue $man 'wtSettingsPath')) {
            Say-Skip $step 'the install did not touch the Windows Terminal profile environment'
            return
        }
        $recorded = $null
        foreach ($f in @(Get-ManValue $man 'files')) { if ($f.path -eq $path) { $recorded = $f.sha256 } }
        if ($recorded -and (Get-Sha256 $path) -eq $recorded) { Say-Skip $step 'settings.json is unchanged since before the install'; return }
    }

    $envObj = Resolve-WtEnvObject $text $eol (-not $Remove)
    if (-not $envObj.Ok) {
        if ($envObj.Absent) { Say-Skip $step 'no profiles.defaults.environment to restore'; return }
        Say-Fail $step $envObj.Error
        return
    }
    $text = $envObj.Text

    # Edits are applied one at a time: inserting a member moves the environment
    # object's closing brace, so the span is re-resolved after every change.
    $work = $envObj.Text
    $notes = @()
    $changes = 0
    foreach ($key in $WtEnvKeys.Keys) {
        $span = Resolve-WtEnvObject $work $eol $false
        if (-not $span.Ok) { break }
        $prop = Find-JsonProp $work $span.Open $span.Close $key
        $current = Get-PropText $work $prop
        $prior = if ($Remove) { Get-ManValue $man.wtEnv $key } else { $current }
        if (-not $Remove) { $script:Man.wtEnv[$key] = $prior }

        $edit = $null
        if ($Remove) {
            if ($null -eq $prior) {
                if ($null -eq $current) { $notes += "$key already absent"; continue }
                if ($current -ne $WtEnvKeys[$key]) { $notes += "$key is '$current', not ours - left alone"; continue }
                $edit = New-RemoveEdit $work $prop $span.Open $span.Close
                $notes += "removed $key"
            } else {
                if ($current -eq $prior) { $notes += "$key already back to '$prior'"; continue }
                if ($prop) { $edit = @{ Start = $prop.ValStart; End = $prop.ValEnd; Text = '"' + $prior + '"' } }
                else { $edit = New-MemberEdit $work $span.Open $span.Close ('"{0}": "{1}"' -f $key, $prior) $eol }
                $notes += "restored $key='$prior'"
            }
        } else {
            if ($current -eq $WtEnvKeys[$key]) { $notes += "$key already $($WtEnvKeys[$key])"; continue }
            if ($prop) { $edit = @{ Start = $prop.ValStart; End = $prop.ValEnd; Text = '"' + $WtEnvKeys[$key] + '"' } }
            else { $edit = New-MemberEdit $work $span.Open $span.Close ('"{0}": "{1}"' -f $key, $WtEnvKeys[$key]) $eol }
            $notes += "set $key=$($WtEnvKeys[$key])"
        }
        $work = Apply-Edits $work @($edit)
        $changes++
    }

    if ($changes -eq 0 -or $work -eq $envObj.Text) { Say-Ok $step ($notes -join '; '); return }
    if ($DryRun) { Say-Changed $step ('would ' + ($notes -join '; ')); return }

    Add-FileRecord $path
    Backup-Once $path
    Save-Text $path $work
    Say-Changed $step ($notes -join '; ')
}

# ------------------------------------------------------------------ user env vars
function Set-UserEnv([bool]$Remove) {
    $step = 'user-env'
    $man = if ($Remove) { Read-Manifest } else { $script:Man }
    if ($SkipUserEnv) {
        # Recorded so -Uninstall does not delete values this install never wrote.
        if (-not $Remove) { $script:Man.userEnvSkipped = $true }
        Say-Skip $step 'skipped (-SkipUserEnv)'
        return
    }
    if ($Remove -and (Get-ManValue $man 'userEnvSkipped')) {
        Say-Skip $step 'the install skipped the user environment (-SkipUserEnv)'
        return
    }
    $notes = @()
    $changed = $false
    foreach ($key in $WtEnvKeys.Keys) {
        $current = [Environment]::GetEnvironmentVariable($key, 'User')
        $prior = if ($Remove) { Get-ManValue $man.userEnv $key } else { $current }
        if (-not $Remove) { $script:Man.userEnv[$key] = $prior }

        if ($Remove) {
            if ($null -eq $prior) {
                if ($null -eq $current) { $notes += "$key already absent"; continue }
                if ($current -ne $WtEnvKeys[$key]) { $notes += "$key is '$current', not ours - left alone"; continue }
                if ($DryRun) { $notes += "would remove $key"; $changed = $true; continue }
                [Environment]::SetEnvironmentVariable($key, $null, 'User')
                $notes += "removed $key"; $changed = $true
            } else {
                if ($current -eq $prior) { $notes += "$key already back to '$prior'"; continue }
                if ($DryRun) { $notes += "would restore $key='$prior'"; $changed = $true; continue }
                [Environment]::SetEnvironmentVariable($key, $prior, 'User')
                $notes += "restored $key='$prior'"; $changed = $true
            }
        } else {
            if ($current -eq $WtEnvKeys[$key]) { $notes += "$key already $current"; continue }
            if ($DryRun) { $notes += "would set $key=$($WtEnvKeys[$key])"; $changed = $true; continue }
            [Environment]::SetEnvironmentVariable($key, $WtEnvKeys[$key], 'User')
            $notes += "set $key=$($WtEnvKeys[$key])"; $changed = $true
        }
    }
    if ($changed) { Say-Changed $step ($notes -join '; ') } else { Say-Ok $step ($notes -join '; ') }
}

# ---------------------------------------------------------------- omp config.yml
function Set-OmpConfig([bool]$Remove) {
    $step = 'omp-config'
    $path = Join-Path $env:USERPROFILE '.omp\agent\config.yml'
    if (-not (Test-Path -LiteralPath $path)) { Say-Fail $step "omp config not found at $path; run omp once, then re-run this script"; return }
    $man = if ($Remove) { Read-Manifest } else { $script:Man }
    $text = Get-Content -LiteralPath $path -Raw
    $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $m = [regex]::Match($text, '(?m)^[ \t]*showImages[ \t]*:[^\r\n]*')

    if ($Remove) {
        if (-not (Get-ManValue $man 'ompConfigPath')) {
            Say-Skip $step 'the install did not touch config.yml'
            return
        }
        $recorded = $null
        foreach ($f in @(Get-ManValue $man 'files')) { if ($f.path -eq $path) { $recorded = $f.sha256 } }
        if ($recorded -and (Get-Sha256 $path) -eq $recorded) { Say-Skip $step 'config.yml is unchanged since before the install'; return }
        $prior = Get-ManValue $man 'showImagesLine'
        if (-not $m.Success) {
            if (-not $prior) { Say-Skip $step 'config.yml carries no showImages line'; return }
            $insert = (Get-ManValue $man 'showImagesIndent')
            if (-not $insert) { $insert = '  ' }
            $new = Add-YamlLine $text 'showImages: true' $eol $insert
            if ($DryRun) { Say-Changed $step 'would restore the showImages line'; return }
            Add-FileRecord $path; Backup-Once $path; Save-Text $path $new
            Say-Changed $step 'restored the showImages line'
            return
        }
        if (-not $m.Value.Trim().EndsWith('true')) { Say-Skip $step "showImages is not ours: $($m.Value.Trim())"; return }
        if ($null -eq $prior) {
            if ($DryRun) { Say-Changed $step 'would remove the showImages line this script added'; return }
            Add-FileRecord $path; Backup-Once $path; Save-Text $path (Remove-Line $text $m $eol)
            Say-Changed $step 'removed the showImages line this script added'
        } else {
            if ($m.Value -eq $prior) { Say-Skip $step "showImages already back to '$($prior.Trim())'"; return }
            if ($DryRun) { Say-Changed $step "would restore: $($prior.Trim())"; return }
            Add-FileRecord $path; Backup-Once $path
            Save-Text $path ($text.Substring(0, $m.Index) + $prior + $text.Substring($m.Index + $m.Length))
            Say-Changed $step "restored: $($prior.Trim())"
        }
        return
    }

    $script:Man.ompConfigPath = $path
    $script:Man.showImagesLine = if ($m.Success) { $m.Value } else { $null }
    $script:Man.showImagesIndent = if ($m.Success) { ([regex]::Match($m.Value, '^[ \t]*')).Value } else { $null }
    if ($m.Success -and $m.Value.Trim().EndsWith('true')) { Say-Ok $step 'terminal.showImages already true'; return }

    if ($DryRun) { Say-Changed $step 'would set terminal.showImages: true'; return }
    Add-FileRecord $path
    Backup-Once $path
    if ($m.Success) {
        $indent = ([regex]::Match($m.Value, '^[ \t]*')).Value
        $new = $text.Substring(0, $m.Index) + $indent + 'showImages: true' + $text.Substring($m.Index + $m.Length)
    } else {
        $new = Add-YamlLine $text 'showImages: true' $eol
    }
    Save-Text $path $new
    Say-Changed $step 'set terminal.showImages: true'
}

# Insert $Line under an existing "terminal:" block (or append a new one), keeping
# the file's EOL. $Indent overrides the derived indentation (used when restoring).
function Add-YamlLine([string]$Text, [string]$Line, [string]$Eol, [string]$Indent) {
    $t = [regex]::Match($Text, '(?m)^terminal[ \t]*:[ \t]*(?=\r?$)')
    if ($t.Success) {
        if (-not $PSBoundParameters.ContainsKey('Indent') -or -not $Indent) { $Indent = (Get-YamlIndent $Text $t.Index) + '  ' }
        return $Text.Substring(0, $t.Index + $t.Length) + $Eol + $Indent + $Line + $Text.Substring($t.Index + $t.Length)
    }
    $sep = if ($Text.Length -eq 0 -or $Text.EndsWith($Eol)) { '' } else { $Eol }
    return $Text + $sep + 'terminal:' + $Eol + '  ' + $Line + $Eol
}

function Get-YamlIndent([string]$Text, [int]$Index) {
    $s = $Index
    while ($s -gt 0 -and $Text[$s - 1] -ne "`n") { $s-- }
    return $Text.Substring($s, $Index - $s)
}

# Delete a matched line, including one line break.
function Remove-Line([string]$Text, $Match, [string]$Eol) {
    $end = $Match.Index + $Match.Length
    if ($end -lt $Text.Length -and $Text[$end] -eq "`r") { $end++ }
    if ($end -lt $Text.Length -and $Text[$end] -eq "`n") { $end++ }
    return $Text.Substring(0, $Match.Index) + $Text.Substring($end)
}

# ------------------------------------------------------------- PowerShell profiles
function Get-ProfilePaths {
    @(
        (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1')
    ) | Where-Object { Test-Path -LiteralPath $_ }
}

function Clean-Profiles {
    $step = 'profiles'
    $paths = Get-ProfilePaths
    if (-not $paths) { Say-Skip $step 'no PowerShell profiles found'; return }
    foreach ($p in $paths) {
        $text = Get-Content -LiteralPath $p -Raw
        $eol = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $hits = @([regex]::Matches($text, '(?m)^[ \t]*\$env:PI_FORCE_IMAGE_PROTOCOL[ \t]*=.*$'))
        if ($hits.Count -le 1) { Say-Skip $step "$([IO.Path]::GetFileName($p)): nothing to collapse ($($hits.Count) line)"; continue }
        if ($DryRun) { Say-Changed $step "would collapse $($hits.Count) duplicate lines in $p"; continue }
        Add-FileRecord $p
        Backup-Once $p
        $new = $text
        foreach ($h in @($hits | Select-Object -Skip 1 | Sort-Object -Property Index -Descending)) { $new = Remove-Line $new $h $eol }
        Save-Text $p $new
        Say-Changed $step "$([IO.Path]::GetFileName($p)): collapsed $($hits.Count) duplicate lines into 1"
    }
}

# --------------------------------------------------------------- omp paste previews
# The composer band and the transcript user message only draw pictures for Kitty, so
# pasted images stay chips on Windows Terminal. tools/patch-paste-images.mjs patches
# those two spots in omp's bundled dist/cli.js (it refuses to write when its anchors
# have moved, and it rolls back by itself if the patched bundle stops booting).
function Invoke-Native([string]$File, [string[]]$Argv) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = @(& $File @Argv 2>&1 | ForEach-Object { [string]$_ }) }
    finally { $ErrorActionPreference = $prev }
    return @{ Code = $LASTEXITCODE; Out = $out }
}

# The patcher's canonical verb: exactly one JSON object on stdout, non-zero exit
# when the patch is missing, stale or unsatisfiable.
function Get-PatcherCheck([string]$Bun, [string]$Tool) {
    $r = Invoke-Native $Bun @($Tool, 'check', '--json')
    $head = ($r.Out -join "`n")
    $start = $head.IndexOf('{')
    $obj = $null
    if ($start -ge 0) { try { $obj = $head.Substring($start) | ConvertFrom-Json } catch { $obj = $null } }
    return @{ Code = $r.Code; Json = $obj; Raw = $r.Out }
}

function Set-PastePreviews([bool]$Remove) {
    $step = 'paste-previews'
    $tool = Join-Path $PSScriptRoot 'tools\patch-paste-images.mjs'
    $bun = Get-Command bun -ErrorAction SilentlyContinue
    if (-not $bun -or -not (Test-Path -LiteralPath $tool)) { Say-Fail $step 'bun or tools/patch-paste-images.mjs missing; pasted images stay text chips'; return }
    $script:Patcher = $null
    $check = Get-PatcherCheck $bun.Source $tool
    $script:Patcher = $check.Json

    if ($DryRun) {
        # A dry run predicts the real outcome, so an unreachable patch fails here too.
        if ($Remove) { Say-Changed $step 'would run: bun tools/patch-paste-images.mjs revert' }
        elseif ($check.Json -and $check.Json.patched -and -not $check.Json.stale) { Say-Ok $step "already patched (rev $($check.Json.patchRev))" }
        elseif ($check.Json -and "$($check.Json.reason)" -like 'unsatisfiable:*') { Say-Fail $step "$($check.Json.reason) - an updated tools/patch-paste-images.mjs is required for this omp build" }
        else { Say-Changed $step 'would run: bun tools/patch-paste-images.mjs apply' }
        return
    }

    if (-not $Remove -and $check.Json -and $check.Json.patched -and -not $check.Json.stale) {
        Say-Ok $step "already patched (rev $($check.Json.patchRev))"
        return
    }
    # No matching anchors means no amount of re-running will land the patch.
    if (-not $Remove -and $check.Json -and "$($check.Json.reason)" -like 'unsatisfiable:*') {
        Say-Fail $step "$($check.Json.reason) - an updated tools/patch-paste-images.mjs is required for this omp build"
        return
    }

    $bundleSha = if ($check.Json) { Get-Sha256 $check.Json.cliPath } else { $null }
    $argv = if ($Remove) { @($tool, 'revert') } else { @($tool, 'apply') }
    $run = Invoke-Native $bun.Source $argv
    foreach ($line in $run.Out) { Write-Step $line }
    if ($run.Code -ne 0) {
        $why = ($run.Out | Where-Object { $_ -match '^\s*\[!!\]' } | Select-Object -Last 1)
        if (-not $why) { $why = ($run.Out | Select-Object -Last 1) }
        Say-Fail $step "the bundle patch did not land: $why"
        return
    }
    if (-not $Remove -and $check.Json -and $check.Json.cliPath) {
        $script:Man.bundle.cliPath = $check.Json.cliPath
        $script:Man.bundle.sha256 = $bundleSha
        $script:Man.bundle.ompVersion = $check.Json.ompVersion
    }
    $tail = ($run.Out | Where-Object { $_ -match '\[' } | Select-Object -Last 1)
    if (-not $tail) { $tail = if ($Remove) { 'reverted to the stock omp bundle' } else { 'pasted images draw as pictures' } }
    Say-Changed $step $tail.Trim()
}

# ----------------------------------------------------------------- uninstall ----
function Invoke-Uninstall {
    $man = Read-Manifest
    if (-not $man) {
        Say-Fail 'manifest' "no manifest at $ManifestPath; nothing to restore from - run install.ps1 first"
        return
    }
    Write-Step "manifest: $ManifestPath"

    Write-Head 'Windows Terminal profile environment'
    Set-WtSettings $true
    Write-Head 'user environment'
    Set-UserEnv $true
    Write-Head 'omp settings'
    Set-OmpConfig $true
    Write-Head 'pasted-image previews'
    Set-PastePreviews $true

    if (-not $DryRun) {
        # The manifest only records the env/config priors; the bundle is reverted
        # from the patcher's own backup, so its failure must not keep the manifest.
        $covered = @('wt-profile-env', 'user-env', 'omp-config')
        $failed = @($script:Results | Where-Object { $_.status -eq 'fail' -and $covered -contains $_.step }).Count
        if ($failed -eq 0) {
            Remove-Item -LiteralPath $ManifestPath -Force
            Write-Step "manifest removed: $ManifestPath"
        } else {
            Write-Step "manifest kept (some restores failed): $ManifestPath"
        }
    }
}

# ------------------------------------------------------------------------ main
Write-Head 'omp-terminal-images'
if ($DryRun) { Write-Warn2 'dry run: nothing will be written' }

$wtVersion = Get-WtVersion
if ($wtVersion) {
    if ($wtVersion -ge [version]'1.22') { Say-Ok 'windows-terminal' "Windows Terminal $wtVersion (SIXEL supported)" }
    else { Say-Fail 'windows-terminal' "Windows Terminal $wtVersion is older than 1.22: no SIXEL. Run: winget upgrade Microsoft.WindowsTerminal" }
} else { Say-Fail 'windows-terminal' 'Windows Terminal package not detected' }

if ($Uninstall) {
    Invoke-Uninstall
} else {
    Write-Head 'Windows Terminal profile environment'
    Set-WtSettings $false

    Write-Head 'user environment'
    Set-UserEnv $false

    Write-Head 'omp settings'
    Set-OmpConfig $false

    Write-Head 'pasted-image previews'
    Set-PastePreviews $false

    if ($CleanProfiles) {
        Write-Head 'PowerShell profiles'
        Clean-Profiles
    }

    Save-Manifest
}

$failures = @($script:Results | Where-Object { $_.status -eq 'fail' }).Count
$warnings = @($script:Results | Where-Object { $_.status -eq 'skip' }).Count

if (-not $Json) {
    Write-Head 'summary'
    foreach ($r in $script:Results) {
        $label = switch ($r.status) { 'fail' { '[!!]' } 'skip' { '[--]' } default { '[ok]' } }
        $color = switch ($r.status) { 'fail' { 'Yellow' } 'skip' { 'DarkGray' } default { 'Green' } }
        Write-Host ("  {0} {1}: {2}" -f $label, $r.step, $r.detail) -ForegroundColor $color
    }
    if ($failures -eq 0) { Write-Host "`n  exit code 0 ($warnings step(s) skipped)" -ForegroundColor Green }
    else { Write-Host "`n  exit code $failures ($warnings step(s) skipped)" -ForegroundColor Yellow }

    Write-Head 'next'
    if ($Uninstall) {
        Write-Host '  Restart Windows Terminal and omp. Backup files remain as *.bak-ompimages.'
    } else {
        Write-Host '  Open a NEW Windows Terminal tab and run:'
        Write-Host '    bun tools/sixel-card.mjs      # should draw a picture'
        Write-Host '    omp                            # then: /debug -> "Test: terminal protocols" -> Graphics - Sixel'
        Write-Host '  Both fixes are read at process start: restart omp to pick them up.'
    }
} else {
    $result = [ordered]@{
        ok              = ($failures -eq 0)
        exitCode        = $failures
        failures        = $failures
        skipped         = $warnings
        dryRun          = [bool]$DryRun
        uninstall       = [bool]$Uninstall
        manifestPath    = $ManifestPath
        manifestWritten = $script:ManifestWritten
        wtVersion       = if ($wtVersion) { "$wtVersion" } else { $null }
        patcher         = $script:Patcher
        steps           = @($script:Results)
    }
    Write-Output ($result | ConvertTo-Json -Depth 8 -Compress)
}

exit $failures
