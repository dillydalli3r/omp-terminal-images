# omp-terminal-images

Inline images in the **oh-my-pi** (`omp`) TUI on **Windows Terminal**.

## TL;DR

```powershell
pwsh -File .\install.ps1          # or: powershell -File .\install.ps1
```

Then open a new Windows Terminal tab and start `omp`. Tool results, model images,
screenshots, bash-emitted graphics **and pasted images** now render as pictures
instead of `[Image: …]` text cards and chips.

Or install it the way the rest of the set ships, through the `omp-addons`
marketplace:

```powershell
omp plugin install terminal-images@omp-addons
```

That path skips `install.ps1`'s env work but adds the reason this is packaged as a
plugin at all: a startup check that re-applies the bundle patch after every `omp`
upgrade — the failure that used to be silent (see
[Update hazard](#update-hazard)).

## The problem

On Windows Terminal everything that carries an image renders as text:

| Surface | Stock omp on WT |
|---|---|
| `read` of a PNG, browser screenshot | `[Image: card.png [image/png] 320x160]` |
| bash output containing SIXEL | same text card |
| pasted clipboard image, composer | `<icon> #1` chip, no preview |
| pasted clipboard image, transcript | `<icon> #1` chip, no picture |

## Root cause

Three facts, all reproducible (verified on omp 18.2.0 and re-checked on 18.2.1,
`@oh-my-pi/pi-tui` 18.2.x, behaviour unchanged since 18.1.22):

1. `detectTerminalId()` (`pi-tui/src/terminal-capabilities.ts`) has **no Windows
   Terminal branch**. WT sets `WT_SESSION`, not `TERM_PROGRAM`, so identity
   resolves to `"base"` → static `imageProtocol = null`.
2. The runtime fallback is a capability probe: the TUI sends `CSI ? 2 ; 1 ; 0 S`
   (XTSMGRAPHICS, SIXEL geometry) and enables SIXEL only if the terminal answers
   (`pi-tui/src/tui.ts`, 250 ms timeout; in 18.2.0 the sequence is inlined rather
   than named).
   **Windows Terminal does not implement that query and never answers** — so the
   probe always times out and images stay off. (`tools/probe-xtsmgraphics.mjs`
   shows the empty reply; `isWindowsTerminalPreviewSixelSupported()` exists in
   the source but has no callers.)
3. WT **can** render SIXEL (since 1.22; this machine: 1.24.11911.0). It only
   never gets asked.

Net effect: an image silently degrades to a text card because the protocol was
never enabled, not because the terminal can't draw it.

## Fix

**1. Pin the protocol.** `PI_FORCE_IMAGE_PROTOCOL` is omp's supported override
and bypasses the probe entirely:

```
PI_FORCE_IMAGE_PROTOCOL=sixel
```

The installer sets it where it covers every shell launched from Windows
Terminal, plus omp's own settings:

| Where | What | Why |
|---|---|---|
| `settings.json` → `profiles.defaults.environment` | `PI_FORCE_IMAGE_PROTOCOL=sixel` | One place, applies to PowerShell, cmd, WSL, Git Bash tabs |
| User environment (`setx`) | same | Terminals and editors that don't inherit the WT profile env |
| `~/.omp/agent/config.yml` | `terminal.showImages: true` | Master switch for inline images |
| User environment (`setx`) | `PI_FORCE_HYPERLINKS=1` | WT resolves to terminal id `base`, whose OSC 8 hyperlinks default to off; this makes image chips Ctrl+clickable |

**2. Patch the two pasted-image surfaces.** Pasted images are the one thing the
env var cannot fix: the composer card and the transcript bubble only draw a
picture for Kitty, so on WT they stay chips. `install.ps1` runs
`bun tools/patch-paste-images.mjs apply`, which patches omp's own bundle (the
`omp-addons` plugin runs the same verb at session start — see
[Update hazard](#update-hazard)):

| Surface | Source that decides it | Patch |
|---|---|---|
| Composer attachment card | `pi-coding-agent/src/modes/components/attachment-chips.ts` — the image interior paints a picture only when `TERMINAL.imageProtocol === ImageProtocol.Kitty && getKittyGraphics().unicodePlaceholders`; every other protocol gets a centered icon | icon fallback → the image itself, drawn by the same `Image` component tool results use, boxed in `│` at its exact edges |
| Transcript entry | `src/modes/utils/ui-helpers.ts` — `imageLinksForMessage()` drops the image bytes to blob links, and the user bubble then collapses `[Image #N, WxH]` to `<icon> #N` | the user/developer branch gets real `Image` children, the same component tool results already draw SIXEL with |

The composer box is drawn *around* the raster instead of by the component, because
the raster is cursor-addressed: the sequence saves the cursor, moves up, paints a
rectangle that runs right and up from where it starts, then restores the cursor to
the saved cell. Text written after it therefore lands back on the image's first
column, and text written before it is painted over. So the interior rows are built
in the patch: `│` + cells + `│` on every row, and on the last one the sequence is
followed by an explicit cursor-forward past the raster before the closing `│` is
written. The raster starts one cell in, so it never touches either border, and it
paints upward over the blank cells of the rows above, which leaves their borders
standing. Corners above and below come from the class's own border builder.

The frame's width is read back from the raster the encoder actually emitted (the
sixel raster attributes, `"1;1;<px>;`), not from the width that was requested: the
encoder refits to `maxHeightCells`, so a 2:1 image requested at 56 cells comes back
48 wide, and the border builder adds the two corners on top of the width it is
handed. Frame height is the raster's own row count, so a shorter chip in a
multi-image band is padded above its image.

An earlier version filled the card's text cells with half blocks (`▀`,
truecolor fg/bg) instead. That is protocol-independent and composes inside any
card, but a half block covers one cell quadrant, so the best the preview can be
is an 8x8 px mosaic — visibly pixelated. It is gone, along with the in-process
PNG decoder and async WebP conversion it needed.

What the preview does instead:

| | Stock | Patched |
|---|---|---|
| Card interior | fixed 12x4 cells, icon | the image, boxed at its exact size |
| Resolution | — | native: the terminal scales the source itself |
| Aspect | — | preserved, center-fit inside the caps |
| Size | 12x4 cells | `MAX_COLS=56` x `MAX_ROWS=12` cells (2:1 image: 48x12 = 432x216 px) |

`MAX_COLS` is an upper bound and `MAX_ROWS` the one that usually binds, so raise
whichever you want — the preview gets bigger, not blurrier. The caps live in
`tools/patch-paste-images.mjs`. `cardW`/`cardH`/`stride` are module-scope vars the
band class already reads, so `render()` just rewrites them before building the
frame — the caption, centering and paste-text paths all follow for free. A band
mixing a text paste and an image sizes both the same height.

Options that were checked first, and why they lost:

- **Extension** — the extension API renders extension-owned messages only.
  `src/extensibility/extensions/types.ts` exposes widgets, overlays, composer
  shapes and `registerMessageRenderer`, but nothing that reaches the internal
  attachment band (`AttachmentChipsBand` is constructed inside
  `src/modes/interactive-mode.ts`), and the built-in user bubble has no renderer
  seam. Not possible without a patch.
- **Config / setting** — there is no preview setting;
  `src/modes/components/settings-defs.ts` only gates on `hasImageProtocol()`.
- **Patching the TypeScript sources** — omp runs `dist/cli.js`, a 22 MB minified
  bundle with pi-tui inlined (`?2;1;0S`, `AttachmentChipsBand` and `Image:()=>kh`
  all appear inside it; the only runtime imports are node builtins and
  `@oh-my-pi/pi-natives`). `src/` is inert at runtime, so the patch has to land
  in the bundle.

Both fixes are read at process start, so an `omp` that was already running when
you installed keeps the old behaviour until you restart it (new sessions started
from a new tab pick them up).

### Update hazard

The paste patch edits a vendored, minified file. **Any `omp` upgrade or
reinstall overwrites it and pasted images go back to being chips.** Re-run
`pwsh -File .\install.ps1` (or `bun tools/patch-paste-images.mjs apply`) after an
upgrade. The patch refuses to write when its anchors have moved, and rolls
itself back if the patched bundle stops booting:

```powershell
bun tools/patch-paste-images.mjs status          # patched? backup? state? every anchor resolved?
bun tools/patch-paste-images.mjs check --json    # one verdict, non-zero exit when not current
bun tools/patch-paste-images.mjs apply
bun tools/patch-paste-images.mjs revert          # restores cli.js.bak-ompimages
```

**Anchors are structural, and every identifier the injected code needs is
captured out of the bundle.** A rename by the minifier does not disable the
patch, and does not wire it to the wrong class either. That is not theoretical:
18.1.22's `Ib`/`Apt`/`tlo`/`b`/`Ct`/`Ee`/`WH` are 18.2.0's
`jk`/`fdt`/`Llo`/`k`/`kt`/`xe`/`hB`, and 18.2.1 moved the inline-image options
helper again — 18.2.0's `function Ha(){let e=Ha()?ke:void 0,…` is 18.2.1's
`function sB(){let e=tl()?ke:void 0,…??Lr("tui.maxInlineImageColumns")`. The
helper is now found by what it *is* (a zero-argument function that reads the
`"tui.maxInlineImageColumns"` literal off the variable it just derived) rather
than by name, so the added `?? Lr(…)` default and the renamed accessor are both
irrelevant. The same review applies to every alias: an alias that several
modules export under the same shape must agree on the name in all of them, and a
`check`/`apply` that cannot satisfy an anchor prints the pattern and the bytes
around where it expected to find it instead of one line that names nothing.

A regex that stops matching makes `apply` and `verify.ps1` fail loudly instead of
degrading into an unpatched bundle with no warning.

**Version gate.** `apply` writes `cli.js.ompimages.json` beside the bundle —
`{ompVersion, cliSha256, patchRev, appliedAt}` — and `check`/`status` compare it
with the file on disk. A bundle patched by an older anchor set, or one whose bytes
changed under it, is reported as `stale` rather than counted as "already patched",
and `apply` re-applies it from the backup. `patchRev` is bumped whenever an edit or
alias regex changes. That is what turns a silent post-upgrade regression into a
reported one:

```json
{
  "ompVersion": "18.2.1",
  "cliPath": "…\\@oh-my-pi\\pi-coding-agent\\dist\\cli.js",
  "patched": true,
  "patchRev": 2,
  "stale": false,
  "reason": ""
}
```

`check --json` always prints exactly that object and exits non-zero unless the
bundle is patched, current and satisfiable. The one reserved `reason` prefix is
`unsatisfiable: ` — the anchors do not resolve against this build, so `apply`
cannot help and a caller must report instead of retrying.

**Startup re-apply.** The plugin registered by
`omp plugin install terminal-images@omp-addons` runs `check --json` at session
start, against the running omp's version, and applies the patch when it is
missing or stale — then says so in one line. When the patch is already current it
stays silent. So an `omp upgrade` no longer needs a manual re-run; the next
session repairs itself. Because the bundle is read at process start, the repair
notices only take effect after omp is restarted, which is what the notice says.
The extension never edits the bundle itself: it shells out to
`tools/patch-paste-images.mjs`, which owns the anchors, the backup, the state file
and the boot self-test. The same verbs are available in-session as
`/terminal-images <status|check|apply|revert|help>`.

Optionally `-CleanProfiles` (on `install.ps1`) collapses duplicated
`$env:PI_FORCE_IMAGE_PROTOCOL` lines left in PowerShell profiles (backed up
first).

## Verify

```powershell
pwsh -File .\verify.ps1
```

Eight checks, in order of strength:

1. **Live TUI** — `pwsh -File tools/live-tui-proof.ps1` spawns its own Windows
   Terminal window, starts an isolated `omp --profile ompimg-proof`, drives the
   composer, screenshots the client area into `docs/` and checks the captured
   pixels against the test card's palette. Scenarios: `bash` (default),
   `paste`, `debug`. All four images in **Verified on** come from this script.
2. **Protocol patch status** — `bun tools/patch-paste-images.mjs status` resolves
   every anchor and every alias in the installed bundle and fails when the
   build is not one the patch understands; `check --json` adds the version gate
   (`patched`, `stale`, `patchRev`) and a non-zero exit whenever the bundle is
   not patched and current.
3. **Headless render** — `omp render --width 120` prints the composed transcript;
   count graphics escapes with `bun tools/check-render.mjs --profile ompimg-proof`
   (render a profile's session *with that profile*, or its `blob:sha256:` image
   refs resolve against the wrong blob store and degrade to text cards).
4. **Terminal capability** — inside a Windows Terminal tab:
   `bun tools/sixel-card.mjs` draws a test card through omp's own render path.
   If you see text, the terminal/protocol is wrong, not omp.
5. **In a running omp session** — `/debug` → `Test: terminal protocols` prints
   `Graphics - Sixel` and draws a gradient sample image.
   (There is no `/terminal-info` slash command in 18.2.0; terminal state is
   `/debug` → `View: terminal state`.)

`tools/detect.mjs` prints the resolved terminal id, protocol, and the
XTSMGRAPHICS probe reply for the current shell.

## What works, what doesn't

| Surface | On Windows Terminal + this fix |
|---|---|
| Tool results with images (`read` on a PNG, screenshots) | ✅ inline picture |
| Assistant/model images | ✅ inline picture |
| Bash output containing SIXEL/Kitty graphics | ✅ extracted into an image result and drawn |
| Composer paste preview (`Ctrl+V`, chip band above the prompt) | ✅ the pasted image itself, sized to `MAX_COLS`x`MAX_ROWS` (picture #2) |
| Transcript for a *pasted* image | ✅ the image itself, drawn at full size (picture #3) |
| Video attachments | card + the preview frame as a picture |
| Image in a session recorded *before* the patch | text card until the session is re-rendered |

The transcript picture is drawn with the same SIXEL path as tool images, so it
respects the live-graphics budget: with many pastes in one session the oldest
images fall back to the text card (`tui.maxInlineImages`, default 8).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `bun tools/sixel-card.mjs` prints text | Terminal < 1.22 or another host (conhost, VS Code) | `winget upgrade Microsoft.WindowsTerminal`; VS Code / conhost have no SIXEL |
| Card renders, transcript doesn't | `terminal.showImages: false` | `omp config set terminal.showImages true` |
| Images stop after a long session | Live-graphics budget (default 8) demotes older images to the text fallback | Raise `tui.maxInlineImages` |
| Big images crowd the transcript | Default caps 100 cols / 20 rows | Lower `tui.maxInlineImageColumns` / `tui.maxInlineImageRows` |
| Paste shows the icon again after an `omp update` | The update replaced `dist/cli.js` | The plugin re-applies it at the next session start and notifies you — `/terminal-images apply` to do it now, or `install.ps1` for the env half too |
| `check --json` reports `stale` or a `patchRev` behind this tool | The bundle was patched by an older anchor set, or its bytes changed since | `bun tools/patch-paste-images.mjs apply` — it restores the backup first, then patches |
| Paste preview never appears | Debug it: `OMP_PASTE_DEBUG=1 omp` logs chip-render errors | `bun tools/patch-paste-images.mjs status`, or `/terminal-images status` in-session |
| Paste preview too small / too big | `MAX_COLS`/`MAX_ROWS` in `tools/patch-paste-images.mjs` | Raise them, then `apply` (bigger, not blurrier) |
| WSL tab: no images | WSL does not inherit WT profile env into the distro env by default | Add `export PI_FORCE_IMAGE_PROTOCOL=sixel` to `~/.bashrc` inside WSL |

## omp will not open (startup spin)

**Symptom.** A new `omp` never paints. The process burns ~100% of one core
indefinitely, no session file is created, and
`~/.omp/logs/omp.<date>.<pid>.log` stops after a single line:

```
global proxy fetch not installed
```

**Root cause.** `~/.omp/plugins/package.json` declared plugin packages that are
not registered in `~/.omp/plugins/omp-plugins.lock.json`. On the machine this
was diagnosed on:

| Declared dependency | Registered in `omp-plugins.lock.json` | Origin |
|---|---|---|
| `@zichuanlan/pi-image-placeholder` (npm) | no | different omp fork (`@earendil-works/pi-*`) |
| `pi-imgcat` | no | same |
| `pi-image-preview` | no | same |

With those installed, startup spins. Removing the three dependency entries and
their `node_modules` directories restores normal startup:

| State | CPU over a 4 s window |
|---|---|
| dependencies installed | 4.0 s (one core pinned) |
| dependencies removed | 0.00–0.19 s (idle TUI) |

Any `omp` started *before* the removal keeps running normally; only new
instances hang.

**Second, smaller cause.** Stale `~/.omp/agent/terminal-sessions/wt-<guid>`
breadcrumbs. Each record is `line1=cwd`, `line2=session jsonl path`, optional
`line3=fresh`. If line 2 names a session file that no longer exists, a fresh
`omp` in that terminal can spin too (13 such records existed here).

**Fix.**

```powershell
pwsh -File .\fix-stuck-startup.ps1
```

Then open a **new** terminal and start `omp`. Both repairs take effect only for
instances started afterwards.

| Flag | Effect |
|---|---|
| *(none)* | Apply both repairs |
| `-DryRun` | Print intended actions, write nothing |
| `-SkipBreadcrumbs` | Only unregister the broken plugin dependencies |
| `-Revert` | Copy quarantined plugin package directories back and restore the `package.json` backup |
| `-QuarantineDir <path>` | Quarantine root, default `~/.omp/.quarantine-ompimages` |

The script reads the registered plugin names from `omp-plugins.lock.json`, backs
up `package.json` once as `package.json.bak-ompimages`, drops each unregistered
dependency key, and moves its package directory out of `node_modules`. It prints
one `[ok]` / `[--]` / `[!!]` line per item and exits 0. Nothing is deleted:
plugin packages land in `<QuarantineDir>\plugins`, breadcrumb files in
`<QuarantineDir>\terminal-sessions`.

**Measuring the spin by hand.** With a fresh `omp` starting:

```powershell
Get-Process bun | Select Id,CPU
```

A hung instance climbs to ~100% of one core; a healthy TUI stays near idle.

## Uninstall

```powershell
pwsh -File .\install.ps1 -Uninstall
```

Reverts the bundle patch (restoring `cli.js.bak-ompimages`), removes the WT
profile env entries and the user env vars, and restores the newest
`settings.json` backup.

## Verified on

Windows 11, Windows Terminal 1.24.11911.0, omp 18.2.1 (`@oh-my-pi/pi-tui` 18.2.1).
The 18.1.22 and 18.2.0 runs this started from are in the git history. The screenshots
below were taken on 18.2.1 — the release that moved the inline-image options helper
and gained the `?? Lr(…)` default the old anchor could not match.

Not every claim here is a picture. The patch verifies itself: `status` resolves
every anchor and alias in the installed bundle, `apply` re-reads the bundle it
just wrote to confirm both regions are present and boots it (`bun cli.js
--version`) before recording the state file, and rolls the backup back if either
check fails; `node --test test/patch-anchors.test.mjs` runs the same anchor logic
against inline 18.2.0/18.2.1 fixtures, including the shapes that must be refused.

Every claim below is a screenshot taken by `tools/live-tui-proof.ps1` from a real
`omp` process in a real Windows Terminal window, not byte-level inference:

| # | Claim | Artifact | Checked by |
|---|---|---|---|
| 1 | WT does not answer the XTSMGRAPHICS probe | — | `bun tools/probe-xtsmgraphics.mjs` inside WT → empty reply |
| 2 | The transcript pipeline emits SIXEL for a tool image | `docs/live-tui-proof.png` | orange 50622 / cyan 66138 / green 32158 px inside the TUI; `check-render --profile ompimg-proof` → 1 SIXEL block (720x360), 0 text cards |
| 3 | The composer card paints the pasted image instead of the icon | `docs/live-paste-composer.png` | 27465 card-palette px inside the card after `Ctrl+V` (0 before the paste), against a floor of `max(300, 3x before)` |
| 4 | The transcript entry for a submitted paste shows the image | `docs/live-paste-transcript.png` | 145029 card-palette px in the transcript (threshold 20000; 8816 + a `🖼 #1` chip with the patch reverted → fails) |
| 5 | omp's own graphics probe draws, and reports `Graphics - Sixel` | `docs/live-debug-probe.png` | 16039 gradient px from `/debug` → `Test: terminal protocols` |
| 6 | WT renders SIXEL at all | — | `tools/sixel-card.mjs` drawn in a WT tab |

Reproduce any of them with:

```powershell
pwsh -File tools/live-tui-proof.ps1 -Scenario bash     # picture 2
pwsh -File tools/live-tui-proof.ps1 -Scenario paste    # pictures 3 + 4 (submits one model turn)
pwsh -File tools/live-tui-proof.ps1 -Scenario paste -ClipboardImage <png>   # any image, to check the card sizing
pwsh -File tools/live-tui-proof.ps1 -Scenario debug    # picture 5
bun tools/check-render.mjs --profile ompimg-proof      # graphics escapes in a rendered transcript
```

The script only ever touches the Windows Terminal window it creates itself, kills
only the omp/bun processes it started, and closes the window again; each run
asserts the omp PID count and WT window count are back to their starting values.

## References

- `@oh-my-pi/pi-tui` `src/terminal-capabilities.ts` — `ImageProtocol`,
  `detectTerminalId`, `resolveImageProtocol`, `isWindowsTerminalPreviewSixelSupported`, `renderImage`
- `@oh-my-pi/pi-tui` `src/tui.ts` — `#querySixelSupport` (XTSMGRAPHICS probe)
- `@oh-my-pi/pi-coding-agent` `src/modes/components/attachment-chips.ts` — the
  Kitty-only preview gate
- `@oh-my-pi/pi-coding-agent` `src/modes/utils/ui-helpers.ts`,
  `src/modes/components/user-message.ts` — why the transcript bubble has no image
- `@oh-my-pi/pi-coding-agent` `src/modes/components/assistant-message.ts:808-837` —
  the image-child pattern the transcript patch copies
- Windows Terminal SIXEL support: 1.22.10352.0 and later
  (<https://github.com/microsoft/terminal/discussions/17889>)

## License

MIT
