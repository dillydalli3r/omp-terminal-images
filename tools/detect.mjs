/**
 * What does omp resolve for THIS shell?
 *
 *   bun tools/detect.mjs
 *
 * Prints terminal identity, the image protocol the TUI would enable, and the
 * reply (if any) to the XTSMGRAPHICS probe omp sends at startup.
 */
import { loadCapabilities, printRows, resolveTuiRoot } from "./lib.mjs";

const { root, mod } = await loadCapabilities();
const {
  TERMINAL,
  TERMINAL_ID,
  ImageProtocol,
  isImageProtocolForced,
  isWindowsTerminalPreviewSixelSupported,
} = mod;

const PROTOCOL_NAMES = new Map([
  [ImageProtocol?.Kitty, "Kitty graphics"],
  [ImageProtocol?.Iterm2, "iTerm2 inline images"],
  [ImageProtocol?.Sixel, "Sixel"],
]);

const env = process.env;
printRows([
  ["pi-tui", root],
  ["terminal id", TERMINAL_ID],
  ["image protocol", TERMINAL.imageProtocol ? (PROTOCOL_NAMES.get(TERMINAL.imageProtocol) ?? "set") : "none (text fallback)"],
  ["forced by env", isImageProtocolForced() ? "yes" : "no"],
  ["WT sixel heuristic", isWindowsTerminalPreviewSixelSupported(env, process.platform) ? "yes" : "no"],
  ["stdin/stdout tty", `${process.stdin.isTTY === true}/${process.stdout.isTTY === true}`],
  ["WT_SESSION", env.WT_SESSION ?? "-"],
  ["TERM_PROGRAM", env.TERM_PROGRAM ?? "-"],
  ["TERM", env.TERM ?? "-"],
  ["PI_FORCE_IMAGE_PROTOCOL", env.PI_FORCE_IMAGE_PROTOCOL ?? "-"],
  ["PI_FORCE_HYPERLINKS", env.PI_FORCE_HYPERLINKS ?? "-"],
  ["hyperlinks (OSC 8)", TERMINAL.hyperlinks ? "on" : "off"],
]);

if (TERMINAL.imageProtocol) {
  console.log("\nimages WILL render inline in this shell.");
} else {
  console.log(
    "\nimages will degrade to [Image: ...] text cards here.\n" +
      "fix: set PI_FORCE_IMAGE_PROTOCOL=sixel and open a new Windows Terminal tab,\n" +
      "     or install via install.ps1 (see README).",
  );
}
