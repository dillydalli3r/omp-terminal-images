/**
 * Shared helpers: locate the @oh-my-pi/pi-tui sources that the installed omp
 * actually resolves, so these tools report the same protocol the TUI uses.
 *
 * Override with OMP_PI_TUI=<path to the @oh-my-pi/pi-tui directory>.
 */
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

const HOME = os.homedir();

/** Candidate install roots, most specific first. */
export function candidateRoots() {
  const appData = process.env.APPDATA ?? path.join(HOME, "AppData", "Roaming");
  const localAppData = process.env.LOCALAPPDATA ?? path.join(HOME, "AppData", "Local");
  const roots = [
    process.env.OMP_PI_TUI,
    path.join(HOME, ".bun", "install", "global", "node_modules", "@oh-my-pi", "pi-tui"),
    path.join(appData, "npm", "node_modules", "@oh-my-pi", "pi-tui"),
    path.join(localAppData, "omp", "node_modules", "@oh-my-pi", "pi-tui"),
    path.join(HOME, ".omp", "plugins", "node_modules", "@oh-my-pi", "pi-tui"),
  ].filter(Boolean);
  // Any profile-scoped install: ~/.omp/profiles/<name>/node_modules/@oh-my-pi/pi-tui
  const profilesDir = path.join(HOME, ".omp", "profiles");
  if (fs.existsSync(profilesDir)) {
    for (const entry of fs.readdirSync(profilesDir)) {
      roots.push(path.join(profilesDir, entry, "node_modules", "@oh-my-pi", "pi-tui"));
    }
  }
  return roots;
}

/** Absolute path of the pi-tui package the tools should load. */
export function resolveTuiRoot() {
  for (const root of candidateRoots()) {
    if (fs.existsSync(path.join(root, "src", "index.ts"))) return root;
  }
  throw new Error(
    `@oh-my-pi/pi-tui not found. Looked in:\n  ${candidateRoots().join("\n  ")}\n` +
      `Set OMP_PI_TUI to the package directory (…/node_modules/@oh-my-pi/pi-tui).`,
  );
}

/** Import pi-tui's capability module from the resolved package. */
export async function loadCapabilities() {
  const root = resolveTuiRoot();
  return { root, mod: await import(pathToFileURL(path.join(root, "src", "terminal-capabilities.ts")).href) };
}

/** Import pi-tui's Image component from the resolved package. */
export async function loadImageComponent() {
  const root = resolveTuiRoot();
  return import(pathToFileURL(path.join(root, "src", "components", "image.ts")).href);
}

/** Print a compact "name: value" block. */
export function printRows(rows) {
  const width = Math.max(...rows.map(([k]) => k.length));
  for (const [k, v] of rows) console.log(`${k.padEnd(width)}  ${v}`);
}
