/**
 * Headless proof: render a session through omp's production transcript pipeline
 * and count the graphics escapes it emitted.
 *
 *   bun tools/check-render.mjs                    # most recent session for this cwd
 *   bun tools/check-render.mjs --session <id|path>
 *
 * `omp render` replays the session into a real InteractiveMode + TUI wired to a
 * byte sink, so these bytes are exactly what a live session writes to the
 * terminal: SIXEL (`ESC P … q`) or Kitty (`ESC _ G`) blocks mean the image
 * surfaces rendered as pictures; `[Image: …]` text means they did not.
 */
import { spawnSync } from "node:child_process";

const argv = process.argv.slice(2);
const sessionIndex = argv.indexOf("--session");
const widthIndex = argv.indexOf("--width");
const session = sessionIndex >= 0 ? argv[sessionIndex + 1] : null;
const width = widthIndex >= 0 ? argv[widthIndex + 1] : "120";

const args = ["render", "--width", width];
if (session) args.push("--session", session);

const proc = spawnSync("omp", args, { encoding: "buffer", maxBuffer: 512 * 1024 * 1024 });
if (proc.error) {
  console.error(`failed to run 'omp render': ${proc.error.message}`);
  process.exit(2);
}
if (proc.status !== 0) {
  console.error(`omp render exited ${proc.status}\n${proc.stderr?.toString().slice(-2000) ?? ""}`);
  process.exit(proc.status ?? 2);
}

const out = proc.stdout;
const text = out.toString("latin1");
const sixel = text.match(/\x1bP[0-9;]*q/g) ?? [];
const kitty = text.match(/\x1b_G/g) ?? [];
const iterm2 = text.match(/\x1b\]1337;File=/g) ?? [];
const textCards = text.match(/\[Image:/g) ?? [];

const rasters = [];
const rasterRe = /\x1bP[0-9;]*q"1;1;(\d+);(\d+)/g;
let m;
while ((m = rasterRe.exec(text))) rasters.push(`${m[1]}x${m[2]}px`);

console.log(`render bytes   ${out.length}`);
console.log(`sixel blocks   ${sixel.length}${rasters.length ? `  (${rasters.slice(0, 6).join(", ")}${rasters.length > 6 ? ", …" : ""})` : ""}`);
console.log(`kitty blocks   ${kitty.length}`);
console.log(`iterm2 blocks  ${iterm2.length}`);
console.log(`text cards     ${textCards.length}`);

if (sixel.length + kitty.length + iterm2.length > 0) {
  console.log("\nPASS: the transcript pipeline emitted terminal graphics.");
  process.exit(0);
}
if (textCards.length > 0) {
  console.log(
    "\nFAIL: images were rendered as text cards — the image protocol is off.\n" +
      "      set PI_FORCE_IMAGE_PROTOCOL=sixel (install.ps1) and re-run.",
  );
  process.exit(1);
}
console.log("\nINCONCLUSIVE: this session contains no image blocks to render.");
process.exit(0);
