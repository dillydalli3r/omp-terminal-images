/**
 * Evidence for the root cause: send the exact capability query omp's TUI sends
 * at startup (`CSI ? 2 ; 1 ; 0 S`, XTSMGRAPHICS) and print the raw reply.
 *
 *   bun tools/probe-xtsmgraphics.mjs      # must run in a real terminal
 *
 * Windows Terminal renders SIXEL but does not implement this query, so the
 * reply is empty and omp's `#querySixelSupport()` times out after 250 ms and
 * leaves the image protocol disabled. xterm/foot/contour answer with
 * `CSI ? 2 ; 0 ; <max geometry> S` and are auto-detected.
 */
if (!process.stdin.isTTY || !process.stdout.isTTY) {
  console.error("run this inside a real terminal (stdin/stdout must be a TTY)");
  process.exit(2);
}

const escaped = s => s.replace(/\x1b/g, "<ESC>");
const readable = s => {
  const out = escaped(s);
  return out.length > 160 ? `${out.slice(0, 160)}…(${s.length} bytes)` : out;
};

process.stdin.setRawMode?.(true);
process.stdin.resume();
let buffer = "";
const onData = chunk => (buffer += chunk.toString("latin1"));
process.stdin.on("data", onData);

process.stdout.write("\x1b[?2;1;0S");
await new Promise(resolve => setTimeout(resolve, 600));

process.stdin.off("data", onData);
process.stdin.setRawMode?.(false);

const match = buffer.match(/\x1b\[\?2;([0-9]+);([0-9;]*)S/u);
console.log(`raw reply      ${buffer.length === 0 ? "(none)" : readable(buffer)}`);
if (!match) {
  console.log("parsed         none -> a SIXEL-capable terminal that does not answer this query");
  console.log("               (Windows Terminal; omp needs PI_FORCE_IMAGE_PROTOCOL=sixel there)");
  process.exit(1);
}
console.log(`parsed         status=${match[1]} geometry=${match[2]}`);
const hasGeometry = match[2].split(";").some(part => Number.parseInt(part, 10) > 0);
console.log(
  hasGeometry && match[1] === "0"
    ? "verdict        SIXEL advertised -> omp auto-detects it, no env var needed"
    : "verdict        no SIXEL geometry advertised",
);
