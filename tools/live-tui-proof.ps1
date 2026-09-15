<#
.SYNOPSIS
  Live proof: a real omp TUI drawing a SIXEL image inside a real Windows Terminal window.

.DESCRIPTION
  Spawns ONE new Windows Terminal window (identified by HWND diff), starts an
  isolated `omp --profile ompimg-proof`, drives it through SendKeys and screenshots
  the client area. Two scenarios:

    -Scenario bash   (default) types `!bun tools/sixel-card.mjs` + Enter and captures
                     docs/live-tui-proof.png: an image tool result drawn by the TUI.
    -Scenario paste  puts the same test card on the clipboard, sends Ctrl+V and
                     captures docs/live-paste-composer.png (the attachment band),
                     then submits and captures docs/live-paste-transcript.png (the
                     transcript entry). The submit is a real model turn.

  Every capture is checked in the captured pixels against the test card's palette
  (orange / cyan / green), so a text fallback fails the run instead of passing.

  Safety: only the window this script created is ever touched or closed, and only
  omp/bun processes descended from the shell this script started AND created after
  the script began are killed. Everything pre-existing is left alone.

.NOTES
  Windows PowerShell 5.1. Run: powershell -NoProfile -File tools/live-tui-proof.ps1 [-Scenario paste]
#>
[CmdletBinding()]
param(
    [ValidateSet('bash', 'paste', 'debug')][string]$Scenario = 'bash',
    [string]$Out = '',
    [string]$Out2 = '',
    [string]$Profile = 'ompimg-proof',
    [string]$RepoPath = '',
    [int]$MinPixels = 20000,
    [int]$MinThumbnailPixels = 300,
    [int]$PaintTimeoutSec = 30
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Drawing

$RepoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { (Get-Location).Path }
if ($RepoPath) { $RepoRoot = $RepoPath }
if (-not $Out) {
    $outName = switch ($Scenario) {
        'paste' { 'docs\live-paste-composer.png' }
        'debug' { 'docs\live-debug-probe.png' }
        default { 'docs\live-tui-proof.png' }
    }
    $Out = Join-Path $RepoRoot $outName
}
if (-not $Out2 -and $Scenario -eq 'paste') { $Out2 = Join-Path $RepoRoot 'docs\live-paste-transcript.png' }
$Out = [System.IO.Path]::GetFullPath($Out)
if ($Out2) { $Out2 = [System.IO.Path]::GetFullPath($Out2) }

$failures = 0
function Ok($m) { Write-Host "[ok] $m" -ForegroundColor Green }
function Bad($m) { Write-Host "[!!] $m" -ForegroundColor Red; $script:failures++ }
function Info($m) { Write-Host "     $m" -ForegroundColor Gray }

Add-Type -ReferencedAssemblies 'System.Drawing' -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;

public class LiveProofNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int n);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

    public static List<IntPtr> Windows() {
        var list = new List<IntPtr>();
        EnumWindows((h, l) => {
            if (!IsWindowVisible(h)) return true;
            var c = new StringBuilder(256);
            GetClassNameW(h, c, 256);
            if (c.ToString() == "CASCADIA_HOSTING_WINDOW_CLASS") list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /** Client-area screenshot of one window (CopyFromScreen; PrintWindow is black for WT). */
    public static Bitmap Capture(IntPtr h) {
        RECT r;
        if (!GetClientRect(h, out r)) return null;
        if (r.Right <= 0 || r.Bottom <= 0) return null;
        POINT p; p.X = 0; p.Y = 0;
        if (!ClientToScreen(h, ref p)) return null;
        var bmp = new Bitmap(r.Right, r.Bottom);
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(p.X, p.Y, 0, 0, new Size(r.Right, r.Bottom));
        }
        return bmp;
    }

    /** Distinct colors on a coarse grid; a uniform (unpainted) window yields 1. */
    public static int DistinctColors(Bitmap bmp) {
        var seen = new HashSet<int>();
        var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = d.Stride, w = bmp.Width, h = bmp.Height;
            byte[] buf = new byte[stride * h];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            for (int y = 0; y < h; y += 4) {
                int row = y * stride;
                for (int x = 0; x < w; x += 4) {
                    int i = row + x * 4;
                    seen.Add(buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16));
                    if (seen.Count > 64) return seen.Count;
                }
            }
        } finally { bmp.UnlockBits(d); }
        return seen.Count;
    }

    /** Counts pixels matching the test card's palette: orange, cyan/blue, green. */
    public static long[] CountCardColors(Bitmap bmp) {
        long orange = 0, cyan = 0, green = 0;
        var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = d.Stride, w = bmp.Width, h = bmp.Height;
            byte[] buf = new byte[stride * h];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            for (int y = 0; y < h; y++) {
                int row = y * stride;
                for (int x = 0; x < w; x++) {
                    int i = row + x * 4;
                    int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                    if (r > 200 && g > 100 && g < 200 && b < 80) orange++;
                    else if (b > 180 && g > 140 && r < 90) cyan++;
                    else if (g > 150 && r < 100 && b < 100) green++;
                }
            }
        } finally { bmp.UnlockBits(d); }
        return new long[] { orange, cyan, green };
    }

    /** Pixels of omp's /debug sample image: r ramps along x, g along y, b pinned to 128. */
    public static long CountProbeGradient(Bitmap bmp, double y0Frac, double y1Frac) {
        long hits = 0;
        int y0 = (int)(bmp.Height * y0Frac), y1 = (int)(bmp.Height * y1Frac);
        if (y0 < 0) y0 = 0;
        if (y1 > bmp.Height) y1 = bmp.Height;
        var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = d.Stride;
            byte[] buf = new byte[stride * bmp.Height];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            for (int y = y0; y < y1; y++) {
                int row = y * stride;
                for (int x = 0; x < bmp.Width; x++) {
                    int i = row + x * 4;
                    int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                    if (Math.Abs(b - 128) < 48 && Math.Abs(r - g) > 64) hits++;
                }
            }
        } finally { bmp.UnlockBits(d); }
        return hits;
    }

    /** Palette count inside the fractional rect [x0Frac,x1Frac) x [y0Frac,y1Frac) of the image. */
    public static long CountCardColorsInRegion(Bitmap bmp, double x0Frac, double x1Frac, double y0Frac, double y1Frac) {
        long orange = 0, cyan = 0, green = 0;
        int x0 = (int)(bmp.Width * x0Frac), x1 = (int)(bmp.Width * x1Frac);
        int y0 = (int)(bmp.Height * y0Frac), y1 = (int)(bmp.Height * y1Frac);
        if (x0 < 0) x0 = 0;
        if (x1 > bmp.Width) x1 = bmp.Width;
        if (y0 < 0) y0 = 0;
        if (y1 > bmp.Height) y1 = bmp.Height;
        var d = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = d.Stride;
            byte[] buf = new byte[stride * bmp.Height];
            Marshal.Copy(d.Scan0, buf, 0, buf.Length);
            for (int y = y0; y < y1; y++) {
                int row = y * stride;
                for (int x = x0; x < x1; x++) {
                    int i = row + x * 4;
                    int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                    if (r > 200 && g > 100 && g < 200 && b < 80) orange++;
                    else if (b > 180 && g > 140 && r < 90) cyan++;
                    else if (g > 150 && r < 100 && b < 100) green++;
                }
            }
        } finally { bmp.UnlockBits(d); }
        return orange + cyan + green;
    }
}
"@

# ---------------------------------------------------------------- process tree
$script:procSnapshot = $null
function Get-ProcTable([switch]$Fresh) {
    if ($Fresh -or -not $script:procSnapshot) {
        $script:procSnapshot = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    }
    return $script:procSnapshot
}
function Get-Descendants([int]$RootPid) {
    $byParent = @{}
    foreach ($p in Get-ProcTable) {
        $k = [int]$p.ParentProcessId
        if (-not $byParent.ContainsKey($k)) { $byParent[$k] = New-Object System.Collections.ArrayList }
        [void]$byParent[$k].Add($p)
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[int]'
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if (-not $byParent.ContainsKey($cur)) { continue }
        foreach ($c in $byParent[$cur]) {
            $cid = [int]$c.ProcessId
            if ($seen.Add($cid)) { $queue.Enqueue($cid) }
        }
    }
    return $seen
}
function Get-OmpPids { return @(Get-Process -Name omp -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }

# ---------------------------------------------------------------- 1. snapshot
Write-Host "`n== omp live TUI proof" -ForegroundColor Cyan
$startedAt = Get-Date
$winBefore = @([LiveProofNative]::Windows())
$ompBefore = Get-OmpPids
Write-Host ("[..] WT windows before: {0} ({1})" -f $winBefore.Count, (($winBefore | ForEach-Object { $_.ToInt64() }) -join ','))
Write-Host ("[..] omp pids before:   {0} ({1})" -f $ompBefore.Count, ($ompBefore -join ','))

$hwnd = [IntPtr]::Zero
$innerPid = 0
$shot = $null
$counts = @(0, 0, 0)
$exitCode = 1

try {
    # ------------------------------------------------------------ 2. spawn window
    $marker = [guid]::NewGuid().ToString('N')
    $pidFile = Join-Path $env:TEMP "omp-live-proof-$marker.pid"

    $innerTemplate = @'
$ErrorActionPreference = 'Continue'
Set-Content -LiteralPath '__PIDFILE__' -Value $PID -Encoding ASCII
Set-Location -LiteralPath '__REPO__'

# Profile isolation: only ever touch ~/.omp/profiles/<name>, never ~/.omp/agent.
$cfg = Join-Path $env:USERPROFILE '.omp\profiles\__PROFILE__\agent\config.yml'
$hasImages = (Test-Path -LiteralPath $cfg) -and ((Get-Content -LiteralPath $cfg -Raw) -match '(?m)^\s*showImages\s*:\s*true\s*$')
if (-not $hasImages) { & omp --profile __PROFILE__ config set terminal.showImages true | Out-Null }

# A fresh profile would otherwise open the 5-step onboarding wizard instead of the TUI.
$env:OMP_SKIP_SETUP = '1'
& omp --profile __PROFILE__
'@
    $inner = $innerTemplate.Replace('__PIDFILE__', $pidFile).Replace('__REPO__', $RepoRoot).Replace('__PROFILE__', $Profile)
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))

    # wt.exe treats ';' as its own command separator, so the inner script travels as -EncodedCommand (base64 UTF-16LE).
    Start-Process -FilePath 'wt.exe' -ArgumentList @('-w', 'new', 'nt', '--title', 'OMP-LIVE-PROOF', 'powershell', '-NoExit', '-EncodedCommand', $enc) | Out-Null
    Ok 'spawned WT window (omp --profile ompimg-proof)'

    # ------------------------------------------------------------ 3. find window + shell
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $pidFile)) { Start-Sleep -Milliseconds 500 }
    if (Test-Path -LiteralPath $pidFile) {
        $innerPid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
        Ok "inner shell pid $innerPid"
    } else {
        Bad "inner shell never reported its pid (no $pidFile)"
    }

    # ------------------------------------------------------------ 4. wait for paint
    $deadline = (Get-Date).AddSeconds($PaintTimeoutSec)
    $painted = $false
    while ((Get-Date) -lt $deadline) {
        if ($hwnd -eq [IntPtr]::Zero) {
            $new = @([LiveProofNative]::Windows() | Where-Object { -not ($winBefore -contains $_) })
            if ($new.Count -gt 0) {
                $hwnd = $new[0]
                [void][LiveProofNative]::ShowWindow($hwnd, 5)
                Ok ("new WT window hwnd {0} (+{1} window(s))" -f $hwnd, $new.Count)
            }
        }
        if ($hwnd -ne [IntPtr]::Zero -and $innerPid -ne 0) {
            $desc = Get-Descendants $innerPid
            $tree = Get-ProcTable
            $ompAlive = @($tree | Where-Object { $desc.Contains([int]$_.ProcessId) -and $_.Name -eq 'omp.exe' }).Count -gt 0
            if ($ompAlive) {
                $b = [LiveProofNative]::Capture($hwnd)
                if ($b) {
                    $distinct = [LiveProofNative]::DistinctColors($b)
                    $b.Dispose()
                    if ($distinct -gt 3) {
                        $painted = $true
                        Ok "TUI painted (throwaway screenshot has $distinct distinct colors)"
                        break
                    }
                }
            }
        }
        Start-Sleep -Seconds 1
    }
    if (-not $painted) { Bad "TUI never painted within ${PaintTimeoutSec}s" }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'no WT window was created; nothing to drive' }

    Start-Sleep -Seconds 2

    # ------------------------------------------------------------ 5. focus + drive
    [void][LiveProofNative]::ShowWindow($hwnd, 5)   # SW_SHOW
    [void][LiveProofNative]::ShowWindow($hwnd, 3)   # SW_MAXIMIZE: fit the whole transcript in one capture
    Start-Sleep -Milliseconds 900
    [void][LiveProofNative]::SetForegroundWindow($hwnd)
    $focused = $false
    $deadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $deadline) {
        if ([LiveProofNative]::GetForegroundWindow() -eq $hwnd) { $focused = $true; break }
        Start-Sleep -Milliseconds 200
    }
    if (-not $focused) {
        [LiveProofNative]::SwitchToThisWindow($hwnd, $true)
        Start-Sleep -Milliseconds 700
        $focused = ([LiveProofNative]::GetForegroundWindow() -eq $hwnd)
        Info 'SetForegroundWindow did not stick; used SwitchToThisWindow fallback'
    }
    if ($focused) { Ok 'window is foreground' } else { Bad 'could not focus own window' }

    $sh = New-Object -ComObject WScript.Shell
    if ($innerPid -ne 0) { try { [void]$sh.AppActivate($innerPid) } catch { } }
    Start-Sleep -Milliseconds 500

    $outDir = Split-Path -Parent $Out
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    function Save-Shot($bmp, $path) { $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png) }

    if ($Scenario -eq 'debug') {
        # omp 18.1.22 has no /terminal-info slash command: terminal state and the graphics
        # probe both live behind /debug. Type-to-filter the menu, then open the entry.
        $sh.SendKeys('/debug')
        Start-Sleep -Milliseconds 400
        $sh.SendKeys('{ENTER}')
        Ok 'sent /debug'
        Start-Sleep -Seconds 2
        $sh.SendKeys('protocols')
        Start-Sleep -Milliseconds 800
        $sh.SendKeys('{ENTER}')
        Ok 'selected "Test: terminal protocols"'
        Start-Sleep -Seconds 3

        if ($shot) { $shot.Dispose(); $shot = $null }
        $shot = [LiveProofNative]::Capture($hwnd)
        if ($shot) { Save-Shot $shot $Out }
        $probe = if ($shot) { [LiveProofNative]::CountCardColorsInRegion($shot, 0.0, 1.0, 0.05, 0.9) } else { 0 }
        $gradient = if ($shot) { [LiveProofNative]::CountProbeGradient($shot, 0.05, 0.9) } else { 0 }
        Info ("captured {0} ({1}x{2})" -f $Out, $shot.Width, $shot.Height)
        Info ("probe gradient pixels: $gradient")
        if ($gradient -ge 2000) { Ok 'the /debug graphics probe drew its sample image' }
        else { Bad 'the /debug graphics probe did not draw (menu navigation or protocol problem)' }
    }
    elseif ($Scenario -eq 'bash') {
        # No SendKeys metacharacters here (no + ^ % ~ ( ) [ ] { }).
        $sh.SendKeys('!bun tools/sixel-card.mjs')
        Start-Sleep -Milliseconds 300
        $sh.SendKeys('{ENTER}')
        Ok 'sent !bun tools/sixel-card.mjs + Enter'
        Start-Sleep -Seconds 4

        # -------------------------------------------------------- 6. capture + check
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            if ($shot) { $shot.Dispose(); $shot = $null }
            $shot = [LiveProofNative]::Capture($hwnd)
            if (-not $shot) { Bad 'capture failed (own window not visible?)'; break }
            Save-Shot $shot $Out
            $counts = [LiveProofNative]::CountCardColors($shot)
            $total = $counts[0] + $counts[1] + $counts[2]
            if ($total -ge $MinPixels) { break }
            if ($attempt -lt 4) { Start-Sleep -Seconds 2 }
        }
        $total = $counts[0] + $counts[1] + $counts[2]
        Info ("captured {0} ({1}x{2})" -f $Out, $shot.Width, $shot.Height)
        Info ("orange={0} cyan={1} green={2} total={3} (threshold {4})" -f $counts[0], $counts[1], $counts[2], $total, $MinPixels)
        if ($total -ge $MinPixels) { Ok 'card palette found in the transcript region' }
        else { Bad 'card palette missing: TUI drew a text fallback or the window was not visible' }
    }
    else {
        # -------------------------------------------------------- 6. paste scenario
        # Put the same test card on the clipboard so the capture can be checked by palette.
        $cardMatch = [regex]::Match((Get-Content -LiteralPath (Join-Path $RepoRoot 'tools\sixel-card.mjs') -Raw), 'CARD_PNG_BASE64 =\s*\r?\n?\s*"([^"]+)"')
        if (-not $cardMatch.Success) { throw 'could not read the test card out of tools/sixel-card.mjs' }
        $clipPath = Join-Path $env:TEMP "omp-live-proof-clip-$marker.png"
        [System.IO.File]::WriteAllBytes($clipPath, [Convert]::FromBase64String($cardMatch.Groups[1].Value))

        Add-Type -AssemblyName System.Windows.Forms
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
            Bad 'this shell is not STA, the clipboard cannot be set — rerun from a normal console'
        }
        $bmp = [System.Drawing.Image]::FromFile($clipPath)
        [System.Windows.Forms.Clipboard]::SetImage($bmp)
        $bmp.Dispose()
        if ([System.Windows.Forms.Clipboard]::ContainsImage()) { Ok "clipboard carries the test card ($clipPath)" }
        else { Bad 'clipboard has no image' }

        # baseline: the band region before the paste
        $before = [LiveProofNative]::Capture($hwnd)
        $bandBefore = if ($before) { [LiveProofNative]::CountCardColorsInRegion($before, 0.0, 0.14, 0.53, 0.75) } else { 0 }
        if ($before) { $before.Dispose() }
        Info "composer band palette before paste: $bandBefore"

        $sh.SendKeys('^v')
        Ok 'sent Ctrl+V'
        Start-Sleep -Seconds 3

        for ($attempt = 1; $attempt -le 4; $attempt++) {
            if ($shot) { $shot.Dispose(); $shot = $null }
            $shot = [LiveProofNative]::Capture($hwnd)
            if (-not $shot) { Bad 'capture failed (own window not visible?)'; break }
            Save-Shot $shot $Out
            $bandAfter = [LiveProofNative]::CountCardColorsInRegion($shot, 0.0, 0.14, 0.53, 0.75)
            if ($bandAfter -ge $MinThumbnailPixels) { break }
            if ($attempt -lt 4) { Start-Sleep -Seconds 2 }
        }
        $bandAfter = [LiveProofNative]::CountCardColorsInRegion($shot, 0.0, 0.14, 0.53, 0.75)
        Info ("captured {0} ({1}x{2})" -f $Out, $shot.Width, $shot.Height)
        Info ("attachment card palette after paste: $bandAfter (threshold $MinThumbnailPixels, before $bandBefore)")
        # The card sits above the editor, so a taller band shifts the rows above it; the
        # decisive signal is that the card region gains card-coloured pixels, not the
        # absolute count (a scrolled banner can contribute a few hundred on its own).
        $bandFloor = [Math]::Max($MinThumbnailPixels, $bandBefore * 3)
        if ($bandAfter -ge $bandFloor) {
            Ok "the attachment card paints the pasted image, not the icon ($bandAfter >= $bandFloor)"
        } else {
            Bad 'composer band shows no thumbnail (patch missing, or omp rendered the icon)'
        }

        # submit -> the transcript entry for the pasted image
        $sh.SendKeys('{ENTER}')
        Ok 'sent Enter to submit the pasted image'
        Start-Sleep -Seconds 6
        if ($shot) { $shot.Dispose(); $shot = $null }
        $shot = [LiveProofNative]::Capture($hwnd)
        if ($shot) { Save-Shot $shot $Out2 }
        $transcript = if ($shot) { [LiveProofNative]::CountCardColorsInRegion($shot, 0.0, 1.0, 0.05, 0.75) } else { 0 }
        $counts = if ($shot) { [LiveProofNative]::CountCardColors($shot) } else { @(0, 0, 0) }
        Info ("captured {0} ({1}x{2})" -f $Out2, $shot.Width, $shot.Height)
        Info ("transcript region palette: $transcript (threshold $MinPixels)")
        if ($transcript -ge $MinPixels) { Ok 'the submitted image renders in the transcript' }
        else { Bad 'no image in the transcript entry for the submitted paste' }
    }

    if ($failures -eq 0) { $exitCode = 0 }
} catch {
    Bad "error: $($_.Exception.Message)"
} finally {
    # ---------------------------------------------------------- 7. cleanup
    Write-Host "`n== cleanup" -ForegroundColor Cyan
    if ($hwnd -ne [IntPtr]::Zero -and [LiveProofNative]::IsWindow($hwnd)) {
        [void][LiveProofNative]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $deadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $deadline -and [LiveProofNative]::IsWindow($hwnd)) { Start-Sleep -Milliseconds 300 }
        if ([LiveProofNative]::IsWindow($hwnd)) { Bad 'own WT window did not close' } else { Ok 'own WT window closed' }
    }
    if ($innerPid -ne 0) {
        $killed = @()
        $desc = Get-Descendants $innerPid
        $tree = Get-ProcTable -Fresh
        foreach ($p in $tree) {
            $pid2 = [int]$p.ProcessId
            if (-not $desc.Contains($pid2)) { continue }
            if ($p.Name -ne 'omp.exe' -and $p.Name -ne 'bun.exe') { continue }
            $created = [Management.ManagementDateTimeConverter]::ToDateTime($p.CreationDate)
            if ($created -le $startedAt) { continue }   # never kill anything older than this run
            Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue
            $killed += "$($p.Name):$pid2"
        }
        if ($killed.Count -gt 0) { Ok ("killed {0}" -f ($killed -join ' ')) } else { Ok 'no child omp/bun processes to kill' }
        Start-Sleep -Seconds 2
        if (Get-Process -Id $innerPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $innerPid -Force -ErrorAction SilentlyContinue
            Info "killed leftover shell pid $innerPid"
        }
    }
    if ($pidFile -and (Test-Path -LiteralPath $pidFile)) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
    if ($clipPath -and (Test-Path -LiteralPath $clipPath)) { Remove-Item -LiteralPath $clipPath -Force -ErrorAction SilentlyContinue }
    if ($shot) { $shot.Dispose() }

    Start-Sleep -Seconds 2
    $ompAfter = Get-OmpPids
    $winAfter = @([LiveProofNative]::Windows())
    if ($ompAfter.Count -eq $ompBefore.Count) { Ok "omp pids back to $($ompBefore.Count) ($($ompAfter -join ','))" }
    else { Bad "omp pid count changed: before $($ompBefore.Count) [$($ompBefore -join ',')] after $($ompAfter.Count) [$($ompAfter -join ',')]"; $exitCode = 1 }
    if ($winAfter.Count -eq $winBefore.Count) { Ok "WT windows back to $($winBefore.Count)" }
    else { Bad "WT window count changed: before $($winBefore.Count) after $($winAfter.Count)"; $exitCode = 1 }
}

if ($exitCode -eq 0) { Write-Host "`nPASS" -ForegroundColor Green } else { Write-Host "`nFAIL" -ForegroundColor Red }
exit $exitCode
