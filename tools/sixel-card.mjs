/**
 * Draw a test card through omp's own image render path.
 *
 *   bun tools/sixel-card.mjs          # run this INSIDE a terminal you want to test
 *   bun tools/sixel-card.mjs --kitty  # force a protocol to compare
 *
 * The card is a 160x80 PNG encoded by the same `renderImage()` the TUI uses for
 * tool results and model images. If you see the picture, the terminal side of
 * the integration is proven; if you see the `[Image: …]` text, the protocol is
 * not enabled (see tools/detect.mjs).
 */
import { loadCapabilities, resolveTuiRoot } from "./lib.mjs";

const CARD_PNG_BASE64 =
  "iVBORw0KGgoAAAANSUhEUgAAAKAAAABQBAMAAABsc2MHAAAAMFBMVEUSIDz/sCAWo0omxv8bJTuHZy7hniPupiItMDn2qyHLkSafditaSzOxgClDPjZdTjMocTO8AAAACXBIWXMAAAsTAAALEwEAmpwYAAABfklEQVR4nO3YMUvDQBQH8DdcaUDa8ob2sBaHfgW/wO0uZhJxyibi0AwObpkKjh1E1yzOFnTXxU1wcBS0H8HFTRCqqEnuCb77D0HyXwM/LpfL3XtH1KRJk3+Z7u750en+1TOIM28zXsY+OYQXbfNXDrPSw41fQ97x7Xx7zCcuGHz96TEfhIKbRY/5IQyM8jI4zILAadlj3gsBo7QK2iwAnFa94hD/CJrKDC5n0anBFZ/HfKEGX/zgSAuaxA8OnBJs+T3mLSV4LIFnSjCWwL4ONJ5V/RHrVGBP8pivVWBHBu9VYFsGJypwIYPrKjCWwb4KnMvgmgrMZXCoAhMZHKjAVAatCpzJ4Go9wBT9ygn6o+ToZTNHL+wY/est0JtDG719ddAbbA99BBj5kKJ6HKMEP+hb6FLEoIslugGXcwQvOA26JCZ00U7wtoLQjQ/BWzOqNI+XFAbSLbi9JXgDToUrgvKlgwYkc/e5eOwj1fOapY4Zg0MNGBwKJ4ppwHFw3gHzSSWIaT/8IAAAAABJRU5ErkJggg==";

const { root, mod } = await loadCapabilities();
const {
  ImageProtocol,
  TERMINAL,
  getImageDimensions,
  renderImage,
  setTerminalImageProtocol,
  imageFallback,
} = mod;

const force = process.argv.includes("--kitty") ? "kitty" : process.argv.includes("--iterm2") ? "iterm2" : process.argv.includes("--sixel") ? "sixel" : null;
if (force) {
  process.env.PI_FORCE_IMAGE_PROTOCOL = force;
  setTerminalImageProtocol(force === "kitty" ? ImageProtocol.Kitty : force === "iterm2" ? ImageProtocol.Iterm2 : ImageProtocol.Sixel);
}

const dims = getImageDimensions(CARD_PNG_BASE64, "image/png");
const result = renderImage(CARD_PNG_BASE64, dims, { maxWidthCells: 40, maxHeightCells: 12 });

console.log(`pi-tui       ${root}`);
console.log(`protocol     ${TERMINAL.imageProtocol ? JSON.stringify(TERMINAL.imageProtocol) : "none"}`);
console.log(`source       ${dims.widthPx}x${dims.heightPx}px`);

if (!result?.sequence) {
  console.log(`result       text fallback (${imageFallback("image/png", dims, "card.png")})`);
  console.log(
    "\nNo graphics: the image protocol is off for this shell.\n" +
      "  - set PI_FORCE_IMAGE_PROTOCOL=sixel and open a NEW Windows Terminal tab, or\n" +
      "  - run install.ps1 (see README.md)\n",
  );
  process.exit(1);
}

console.log(`result       ${result.sequence.length} byte graphics sequence, ${result.rows} rows\n`);
process.stdout.write(result.sequence);
process.stdout.write("\n^ the card above must show a yellow circle, a cyan rectangle and a green bar\n");
