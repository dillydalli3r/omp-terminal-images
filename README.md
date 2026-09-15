# omp-terminal-images

Inline images in the **oh-my-pi** (`omp`) TUI on **Windows Terminal**.

## TL;DR

```powershell
pwsh -File .\install.ps1          # or: powershell -File .\install.ps1
```

Then open a new Windows Terminal tab and start `omp`. Tool results, model
images, screenshots and bash-emitted graphics now render as pictures instead of
`[Image: …]` text cards. Verify with `/terminal-info` → `Graphics: Sixel`.

## The problem

On Windows Terminal everything that carries an image (a `read` of a PNG, a
screenshot from the browser tool, a pasted screenshot, a bash command that
prints SIXEL) renders as a text card:

```
[Image: card.png [image/png] 320x160]
```

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

Pin the protocol. `PI_FORCE_IMAGE_PROTOCOL` is omp's supported override and
bypasses the probe entirely:

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

Optionally `-CleanProfiles` collapses duplicated `$env:PI_FORCE_IMAGE_PROTOCOL`
lines left in PowerShell profiles (backed up first).

## Verify

```powershell
pwsh -File .\verify.ps1
```

Four checks, in order of strength:

1. **Terminal capability** — inside a Windows Terminal tab:
   `bun tools/sixel-card.mjs` draws a test card through omp's own render path.
   You should see the picture. If you see text, the terminal/protocol is wrong,
   not omp.
2. **What omp resolved** — in a running omp session: `/terminal-info` must print
   `Graphics:     Sixel`.
3. **Live transcript** — in omp: `/debug` → the graphics/image probe draws a
   sample image inline.
4. **Headless proof** — `omp render --width 120` prints the composed transcript;
   count graphics escapes with `bun tools/check-render.mjs <session.jsonl>`.

`tools/detect.mjs` prints the resolved terminal id, protocol, and the XTSMGRAPHICS
probe reply for the current shell.

## What works, what doesn't

| Surface | On Windows Terminal + this fix |
|---|---|
| Tool results with images (`read` on a PNG, screenshots) | ✅ inline picture |
| Assistant/model images, pasted-image *transcript* entries | ✅ chip + dimension label; the picture itself is shown for tool/model images |
| Bash output containing SIXEL/Kitty graphics | ✅ extracted into an image result and drawn |
| Composer paste preview (`Ctrl+V` an image, chip band above the prompt) | ⚠️ chip with icon + pixel size, **no thumbnail** — see below |
| Transcript for a *pasted* image | ⚠️ compact `<icon> #N` chip, not a picture |

### Why the pasted-image chip has no thumbnail

`AttachmentChipsBand.#imageInterior()` only paints a live thumbnail for
`ImageProtocol.Kitty` **with** Unicode placeholders; every other protocol falls
back to a centered icon, because Kitty placeholders are real text cells that can
be composed inside a bordered card, while SIXEL is a cursor-addressed DCS that
would paint over the card. So on WT the paste preview is an icon, by design, in
this version.

Workarounds:

- **Ctrl+click the `[Image #1]` chip** — it is an OSC 8 hyperlink to the blob
  written on paste; with `PI_FORCE_HYPERLINKS=1` set by the installer this opens
  the image in the default viewer. (WT needs the force: terminal id `base` has
  hyperlinks off.)
- **Submit anyway** — the model receives the real image; only the preview is an
  icon.
- **Use a Kitty-graphics terminal** (Ghostty, WezTerm, kitty) if you want live
  paste thumbnails; those are auto-detected, no env var needed.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/terminal-info` shows `Graphics: none` | Env var not visible to the process | Start omp from a terminal opened *after* the install, or run `set PI_FORCE_IMAGE_PROTOCOL=sixel` first |
| `bun tools/sixel-card.mjs` prints text | Terminal < 1.22 or another host (conhost, VS Code) | `winget upgrade Microsoft.WindowsTerminal`; VS Code / conhost have no SIXEL |
| Card renders, transcript doesn't | `terminal.showImages: false` | `omp config set terminal.showImages true` |
| Images stop after a long session | Live-graphics budget (default 8) demotes older images to the text fallback | Raise `tui.maxInlineImages` |
| Big images crowd the transcript | Default caps 100 cols / 20 rows | Lower `tui.maxInlineImageColumns` / `tui.maxInlineImageRows` |
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

A hung instance climbs to ~100% of one core; a healthy TUI stays near idle. This
is also the failure the **Verified on** section ran into when starting a second
`omp` — same cause, same fix.

## Uninstall

```powershell
pwsh -File .\install.ps1 -Uninstall
```

Removes the WT profile env entries and the user env vars, and restores the
newest `settings.json` backup.

## Verified on

Windows 11, Windows Terminal 1.24.11911.0, omp 18.1.22 (`@oh-my-pi/pi-tui` 18.1.22):

| Claim | How it was checked | Result |
|---|---|---|
| WT does not answer the XTSMGRAPHICS probe | `bun tools/probe-xtsmgraphics.mjs` inside WT | empty reply, no `CSI ? 2 ; … S` |
| Images are dropped without the env var | `omp render` on a session whose transcript contained image tool results | `[Image: card.png [image/png] 160x80]` text card, 0 graphics blocks |
| The transcript pipeline emits SIXEL with the env var | `bun tools/check-render.mjs` on the same session | 14 SIXEL blocks, e.g. `657x360px` |
| WT renders SIXEL | `tools/sixel-card.mjs` drawn in a WT tab, then screenshotted | picture visible |
| Bash output containing graphics becomes an image result | a bash call printing the sixel card, through the live session | the card came back as a decoded image (orange circle, cyan rectangle, green bar) |

Not verified with a screenshot: a *live* omp process painting those bytes into
Windows Terminal, because starting a second `omp` while another session is open
turned out to be unreliable on this machine (startup spins without creating a
session, most visibly when passing an initial message). Confirm locally with
`/terminal-info` and the `/debug` graphics probe.

## References

- `@oh-my-pi/pi-tui` `src/terminal-capabilities.ts` — `ImageProtocol`,
  `detectTerminalId`, `resolveImageProtocol`, `isWindowsTerminalPreviewSixelSupported`, `renderImage`
- `@oh-my-pi/pi-tui` `src/tui.ts` — `#querySixelSupport` (XTSMGRAPHICS probe)
- `@oh-my-pi/pi-coding-agent` `src/modes/components/attachment-chips.ts` — Kit
  thumbnail gate
- Windows Terminal SIXEL support: 1.22.10352.0 and later
  (<https://github.com/microsoft/terminal/discussions/17889>)

## License

MIT
