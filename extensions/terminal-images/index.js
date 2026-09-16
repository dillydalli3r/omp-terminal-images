// OMP extension: keep the terminal-images bundle patch applied across omp upgrades.
//
// Built-in Node modules only: the plugin is installed from the omp-addons marketplace and carries no
// dependency tree of its own.
//
// Why an extension and not the patch itself: the patch has to edit the vendored, minified
// `@oh-my-pi/pi-coding-agent/dist/cli.js`, and every omp upgrade replaces that file — pasted images
// silently go back to being chips. This extension notices and repairs it at session start, and gives
// the same verbs to a slash command. It never edits the bundle itself; it shells out to the patcher
// that lives beside it in the same package (`tools/patch-paste-images.mjs`), which owns the anchors,
// the backup, the state file and the boot self-test.

import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PATCHER = fileURLToPath(new URL("../../tools/patch-paste-images.mjs", import.meta.url));
const PATCHER_DIR = path.dirname(PATCHER);
const IS_WINDOWS = process.platform === "win32";
const RELOAD_MSG = "Restart omp for it to take effect.";
const TIMEOUT_MS = 120_000;

function notify(ctx, message, level = "info") {
  // Never throw out of a notification: a print run or an RPC session has no ui, and a dead notify
  // must not abort the check that produced it.
  try {
    ctx?.ui?.notify?.(String(message), level);
  } catch {}
}

function firstLine(text) {
  return (
    String(text ?? "")
      .split("\n")
      .map(line => line.trim())
      .filter(Boolean)[0] || ""
  );
}

// `bun` on Windows is `bun.cmd`, which only the shell resolves.
function cliCommand(name, args) {
  const argv = args.map(arg => (/\s/.test(arg) ? `"${arg}"` : arg));
  return IS_WINDOWS ? [process.env.ComSpec || "cmd.exe", ["/c", name, ...argv]] : [name, argv];
}

function runPatcher(pi, args) {
  const [command, argv] = cliCommand("bun", [PATCHER, ...args]);
  return pi.exec(command, argv, { cwd: PATCHER_DIR, timeout: TIMEOUT_MS });
}

// The patcher prints one JSON object, but a stray warning on stdout must not blind this.
function parseCheck(stdout) {
  const text = String(stdout ?? "");
  const at = text.indexOf("{");
  if (at < 0) return null;
  try {
    const info = JSON.parse(text.slice(at));
    return info && typeof info === "object" ? info : null;
  } catch {
    return null;
  }
}

function normVersion(value) {
  const match = /(\d+\.\d+\.\d+(?:-[\w.]+)?)/.exec(String(value ?? ""));
  return match ? match[1] : "";
}

// The running build. The injected SDK exposes it (`pi.pi.VERSION` is the agent's own version, the
// same string `omp --version` prints after its `omp/` prefix); the CLI is the fallback.
async function runningVersion(pi) {
  const injected = normVersion(pi?.pi?.VERSION);
  if (injected) return injected;
  try {
    const [command, argv] = cliCommand("omp", ["--version"]);
    const result = await pi.exec(command, argv, { timeout: 20_000 });
    return normVersion(`${result.stdout} ${result.stderr}`);
  } catch {
    return "";
  }
}

// Startup runs off the turn, so nothing here is allowed to gate the first prompt or throw into the
// session. Silent when the patch is applied and current; one line when it was repaired or cannot be.
async function checkPatch(pi, ctx) {
  if (!existsSync(PATCHER)) return;
  const seen = await runPatcher(pi, ["check", "--json"]);
  const info = parseCheck(seen.stdout);
  if (!info) {
    notify(
      ctx,
      `terminal-images: cannot read the patch state — ${firstLine(seen.stderr) || firstLine(seen.stdout) || `bun exited ${seen.code}`}`,
      "warning",
    );
    return;
  }
  // `unsatisfiable` is the patch's reserved prefix for "this build is not one the anchors
  // understand": applying cannot help, so say so instead of retrying on every start.
  if (String(info.reason || "").startsWith("unsatisfiable:")) {
    notify(ctx, `terminal-images: ${String(info.reason).replace(/^unsatisfiable:\s*/, "")}`, "warning");
    return;
  }

  const running = await runningVersion(pi);
  const drift = Boolean(running && info.ompVersion && running !== info.ompVersion);
  if (info.patched && !info.stale && !drift) return;

  const why = !info.patched ? "was missing" : drift ? `was applied to omp ${info.ompVersion}` : "was stale";
  const applied = await runPatcher(pi, ["apply"]);
  if (applied.code === 0) {
    notify(
      ctx,
      `terminal-images: the image patch ${why} — re-applied for omp ${running || info.ompVersion || "?"}. ${RELOAD_MSG}`,
      "warning",
    );
    return;
  }
  notify(
    ctx,
    `terminal-images: could not re-apply the image patch — ${firstLine(applied.stderr) || firstLine(applied.stdout) || `bun exited ${applied.code}`}`,
    "error",
  );
}

function renderVerdict(info) {
  const lines = [
    `terminal-images: omp ${info.ompVersion || "?"} — patched ${info.patched ? "yes" : "no"}, stale ${info.stale ? "yes" : "no"}, patch rev ${info.patchRev}`,
  ];
  if (info.reason) lines.push(`  ${info.reason}`);
  if (info.cliPath) lines.push(`  ${info.cliPath}`);
  return lines.join("\n");
}

const USAGE = [
  "/terminal-images            status — patch state and every resolved anchor",
  "/terminal-images check      one verdict, exits non-zero when the patch is missing or stale",
  "/terminal-images apply      patch (or re-patch) the installed omp bundle",
  "/terminal-images revert     restore cli.js from cli.js.bak-ompimages",
  "/terminal-images help",
].join("\n");

export default function ompTerminalImages(pi) {
  pi.setLabel?.("Terminal images");

  pi.registerCommand("terminal-images", {
    description:
      "Inline-image bundle patch for the omp TUI. Usage: /terminal-images <status|check|apply|revert|help>",
    handler: async (args, ctx) => {
      const verb = (String(args || "").trim().split(/\s+/).filter(Boolean)[0] || "status").toLowerCase();
      if (verb === "help") {
        notify(ctx, USAGE, "info");
        return;
      }
      if (!existsSync(PATCHER)) {
        notify(ctx, `terminal-images: tools/patch-paste-images.mjs is missing from the plugin install (${PATCHER})`, "error");
        return;
      }
      try {
        if (verb === "apply" || verb === "revert") {
          const result = await runPatcher(pi, [verb]);
          const ok = result.code === 0;
          const text = firstLine(result.stdout) || firstLine(result.stderr) || `bun exited ${result.code}`;
          notify(
            ctx,
            `terminal-images: ${verb} ${ok ? "ok" : "failed"} — ${text}${verb === "apply" && ok ? ` ${RELOAD_MSG}` : ""}`,
            ok ? "info" : "error",
          );
          return;
        }
        if (verb === "check") {
          const result = await runPatcher(pi, ["check", "--json"]);
          const info = parseCheck(result.stdout);
          if (!info) {
            notify(
              ctx,
              `terminal-images: check failed — ${firstLine(result.stderr) || firstLine(result.stdout) || `bun exited ${result.code}`}`,
              "error",
            );
            return;
          }
          notify(ctx, renderVerdict(info), info.patched && !info.stale ? "info" : "warning");
          return;
        }
        const result = await runPatcher(pi, ["status"]);
        const text = String(result.stdout ?? "").trim() || firstLine(result.stderr);
        notify(ctx, text ? `terminal-images:\n${text}` : `terminal-images: status failed — bun exited ${result.code}`, result.code === 0 ? "info" : "warning");
      } catch (cause) {
        notify(ctx, `terminal-images: ${cause?.message || cause}`, "error");
      }
    },
  });

  pi.on("session_start", (_event, ctx) => {
    // Fire and forget: startup is never gated on spawning bun, and a failure here is reported
    // through the notification, not as a session error.
    checkPatch(pi, ctx).catch(() => {});
  });
}
