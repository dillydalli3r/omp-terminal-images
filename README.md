# omp-terminal-images

Inline images in the **oh-my-pi** (`omp`) TUI on **Windows Terminal**.

## TL;DR

```powershell
pwsh -File .\install.ps1          # or: powershell -File .\install.ps1
```

Then open a new Windows Terminal tab and start `omp`. Tool results, model images,
screenshots, bash-emitted graphics **and pasted images** now render as pictures
instead of `[Image: …]` text cards and chips.

## The problem

On Windows Terminal everything that carries an image renders as text:

| Surface | Stock omp 18.1.22 on WT |
|---|---|
| `read` of a PNG, browser screenshot | `[Image: card.png [image/png] 320x160]` |
| bash output containing SIXEL | same text card |
| pasted clipboard image, composer | `<icon> #1` chip, no thumbnail |
| pasted clipboard image, transcript | `<icon> #1` chip, no picture |

## Root cause

Three facts, all reproducible (omp 18.1.22, `@oh-my-pi/pi-tui` 18.1.22):

1. `detectTerminalId()` (`pi-tui/src/terminal-capabilities.ts`) has **no Windows
   Terminal branch**. WT sets `WT_SESSION`, not `TERM_PROGRAM`, so identity
   resolves to `"base"` → static `imageProtocol = null`.
2. The runtime fallback is a capability probe: the TUI sends `CSI ? 2 ; 1 ; 0 S`
   (XTSMGRAPHICS, SIXEL geometry) and enables SIXEL only if the terminal answers
   (`pi-tui/src/tui.ts`, `#querySixelSupport`, 250 ms timeout).
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
`bun tools/patch-paste-images.mjs apply`, which patches omp's own bundle:

| Surface | Source that decides it | Patch |
|---|---|---|
| Composer attachment card | `pi-coding-agent/src/modes/components/attachment-chips.ts:118-155` — `#imageInterior()` paints a thumbnail only when `TERMINAL.imageProtocol === ImageProtocol.Kitty && getKittyGraphics().unicodePlaceholders`; every other protocol gets a centered icon | icon fallback → truecolor half-block (`▀`) thumbnail, decoded in-process |
| Transcript entry | `src/modes/utils/ui-helpers.ts:104-124` — `imageLinksForMessage()` drops the image bytes to blob links; `src/modes/components/user-message.ts:50` then collapses `[Image #N, WxH]` to `<icon> #N` | the user/developer branch gets real `Image` children, the same component tool results already draw SIXEL with |

Why a half-block thumbnail in the card instead of the real image: Kitty
placeholders are ordinary text cells and compose inside a bordered card, while
SIXEL is a cursor-addressed DCS that paints over the card border. Half-blocks
are text cells too, so the card survives; they are also protocol-independent
(truecolor `▀` with fg/bg), so the same code works on any 24-bit terminal.

Options that were checked first, and why they lost:

- **Extension** — the extension API renders extension-owned messages only.
  `src/extensibility/extensions/types.ts` exposes widgets, overlays, composer
  shapes and `registerMessageRenderer`, but nothing that reaches the internal
  attachment band (`AttachmentChipsBand` is constructed inside
  `src/modes/interactive-mode.ts`), and the built-in user bubble has no renderer
  seam. Not possible without a patch.
- **Config / setting** — there is no thumbnail setting;
  `src/modes/components/settings-defs.ts` only gates on `hasImageProtocol()`.
- **Patching the TypeScript sources** — omp runs `dist/cli.js`, a 22 MB minified
  bundle with pi-tui inlined (`?2;1;0S`, `AttachmentChipsBand` and `Image:()=>kh`
  all appear inside it; the only runtime imports are node builtins and
  `@oh-my-pi/pi-natives`). `src/` is inert at runtime, so the patch has to land
  in the bundle.

### Update hazard

The paste patch edits a vendored, minified file. **Any `omp` upgrade or
reinstall overwrites it and the paste thumbnails silently disappear.** Re-run
`pwsh -File .\install.ps1` (or `bun tools/patch-paste-images.mjs apply`) after an
upgrade. The patch refuses to write when its anchors have moved, and rolls
itself back if the patched bundle stops booting:

```powershell
bun tools/patch-paste-images.mjs status    # patched? backup present? anchors found?
bun tools/patch-paste-images.mjs apply
bun tools/patch-paste-images.mjs revert     # restores cli.js.bak-ompimages
```

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
2. **Protocol patch status + decoder self-test** — `bun tools/check-png-thumb.mjs`
   decodes the real test card plus synthetic PNGs covering every colour type and
   scanline filter, and the WebP path omp actually uses for pastes.
3. **Headless render** — `omp render --width 120` prints the composed transcript;
   count graphics escapes with `bun tools/check-render.mjs --profile ompimg-proof`
   (render a profile's session *with that profile*, or its `blob:sha256:` image
   refs resolve against the wrong blob store and degrade to text cards).
4. **Terminal capability** — inside a Windows Terminal tab:
   `bun tools/sixel-card.mjs` draws a test card through omp's own render path.
   If you see text, the terminal/protocol is wrong, not omp.
5. **In a running omp session** — `/debug` → `Test: terminal protocols` prints
   `Graphics - Sixel` and draws a gradient sample image.
   (There is no `/terminal-info` slash command in 18.1.22; terminal state is
   `/debug` → `View: terminal state`.)

`tools/detect.mjs` prints the resolved terminal id, protocol, and the
XTSMGRAPHICS probe reply for the current shell.

## What works, what doesn't

| Surface | On Windows Terminal + this fix |
|---|---|
| Tool results with images (`read` on a PNG, screenshots) | ✅ inline picture |
| Assistant/model images | ✅ inline picture |
| Bash output containing SIXEL/Kitty graphics | ✅ extracted into an image result and drawn |
| Composer paste preview (`Ctrl+V`, chip band above the prompt) | ✅ half-block thumbnail of the pasted image (picture #2) |
| Transcript for a *pasted* image | ✅ the image itself, drawn at full size (picture #3) |
| Video attachments | card + half-block thumbnail for the preview frame |
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
| Paste shows the icon again after an `omp update` | The update replaced `dist/cli.js` | Re-run `install.ps1` |
| Paste thumbnail never appears | Debug it: `OMP_PASTE_DEBUG=1 omp` logs decoder/conversion failures | `bun tools/patch-paste-images.mjs status` |
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

Windows 11, Windows Terminal 1.24.11911.0, omp 18.1.22 (`@oh-my-pi/pi-tui` 18.1.22).

Every claim below is a screenshot taken by `tools/live-tui-proof.ps1` from a real
`omp` process in a real Windows Terminal window, not byte-level inference:

| # | Claim | Artifact | Checked by |
|---|---|---|---|
| 1 | WT does not answer the XTSMGRAPHICS probe | — | `bun tools/probe-xtsmgraphics.mjs` inside WT → empty reply |
| 2 | The transcript pipeline emits SIXEL for a tool image | `docs/live-tui-proof.png` | orange 50503 / cyan 64896 / green 32771 px inside the TUI; `check-render --profile ompimg-proof` → 1 SIXEL block (720x360), 0 text cards |
| 3 | The composer card paints the pasted image instead of the icon | `docs/live-paste-composer.png` | card palette in the attachment band 563 px after `Ctrl+V` (threshold 300; 0 before the paste, 49 with the patch reverted) |
| 4 | The transcript entry for a submitted paste shows the image | `docs/live-paste-transcript.png` | 156423 card-palette px in the transcript (threshold 20000; 5053 and a `🖼 #1` chip with the patch reverted) |
| 5 | omp's own graphics probe draws, and reports `Graphics - Sixel` | `docs/live-debug-probe.png` | 15046 gradient px from `/debug` → `Test: terminal protocols` |
| 6 | WT renders SIXEL at all | — | `tools/sixel-card.mjs` drawn in a WT tab |

Reproduce any of them with:

```powershell
pwsh -File tools/live-tui-proof.ps1 -Scenario bash     # picture 2
pwsh -File tools/live-tui-proof.ps1 -Scenario paste    # pictures 3 + 4 (submits one model turn)
pwsh -File tools/live-tui-proof.ps1 -Scenario debug    # picture 5
bun tools/check-png-thumb.mjs                          # decoder, all colour types + filters
```

The script only ever touches the Windows Terminal window it creates itself, kills
only the omp/bun processes it started, and closes the window again; each run
asserts the omp PID count and WT window count are back to their starting values.

## References

- `@oh-my-pi/pi-tui` `src/terminal-capabilities.ts` — `ImageProtocol`,
  `detectTerminalId`, `resolveImageProtocol`, `isWindowsTerminalPreviewSixelSupported`, `renderImage`
- `@oh-my-pi/pi-tui` `src/tui.ts` — `#querySixelSupport` (XTSMGRAPHICS probe)
- `@oh-my-pi/pi-coding-agent` `src/modes/components/attachment-chips.ts` — Kit
  thumbnail gate
- `@oh-my-pi/pi-coding-agent` `src/modes/utils/ui-helpers.ts`,
  `src/modes/components/user-message.ts` — why the transcript bubble has no image
- `@oh-my-pi/pi-coding-agent` `src/modes/components/assistant-message.ts:808-837` —
  the image-child pattern the transcript patch copies
- Windows Terminal SIXEL support: 1.22.10352.0 and later
  (<https://github.com/microsoft/terminal/discussions/17889>)

## License

MIT
