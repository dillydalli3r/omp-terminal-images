/**
 * Check the thumbnail decoder that tools/patch-paste-images.mjs injects into omp.
 *
 *   bun tools/check-png-thumb.mjs
 *
 * The paste patch turns a pasted image into a truecolor half-block ("▀") thumbnail.
 * The decoder shipped inside that patch is the only non-obvious code in the repo, so
 * this exercises it directly: it lifts the injected helper out of the patch script,
 * runs it over the real test card plus synthetic PNGs covering every colour type and
 * filter, and checks the failure modes fall back to the icon instead of throwing.
 */
import { readFileSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync, inflateSync } from "node:zlib";

const here = path.dirname(fileURLToPath(import.meta.url));

// ---------------------------------------------------------------- load the helper
const tooling = readFileSync(path.join(here, "patch-paste-images.mjs"), "utf8");
const start = tooling.indexOf('const HELPER = `${MARK}');
const end = tooling.indexOf("\n`;", start);
if (start < 0 || end < 0) {
  console.error("could not find HELPER in tools/patch-paste-images.mjs");
  process.exit(2);
}
const source = tooling
  .slice(start + "const HELPER = `".length, end)
  .replaceAll("${MARK}", "/*mark*/")
  .replace('import{inflateSync as __ompInflate}from"node:zlib";', "");
const api = new Function("__ompInflate", `${source}\nreturn globalThis.__ompPasteImages;`)(inflateSync);

const cardB64 = /CARD_PNG_BASE64 =\s*\n?\s*"([^"]+)"/.exec(
  readFileSync(path.join(here, "sixel-card.mjs"), "utf8"),
)[1];

// The literal in the patch carries `\u001b`, which the bundle turns into ESC at parse time;
// this harness compiles it the same way, so unescape once more when inspecting the output.
const esc = t => t.replaceAll("\\u001b", "\u001b").replaceAll("\\u2580", "\u2580");
const plain = t => esc(t).replace(/\u001b\[[0-9;]*m/g, "");
const palette = t => {
  const cols = [...esc(t).matchAll(/(?:38|48);2;(\d+);(\d+);(\d+)m/g)].map(m => m.slice(1).map(Number));
  return {
    total: cols.length,
    orange: cols.filter(([r, g, b]) => r > 200 && g > 100 && g < 200 && b < 80).length,
    cyan: cols.filter(([r, g, b]) => b > 180 && g > 140 && r < 90).length,
    green: cols.filter(([r, g, b]) => g > 150 && r < 100 && b < 100).length,
  };
};

// ------------------------------------------------------------- PNG encoder (test side)
function crc32(buf) {
  let c,
    crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = c ^ (crc >>> 8);
  }
  return (crc ^ 0xffffffff) >>> 0;
}

/** 8-bit PNG of a WxH RGBA buffer, with a chosen colour type and scanline filter. */
function png(w, h, rgba, { colorType = 6, filter = 0 } = {}) {
  const ch = { 0: 1, 2: 3, 4: 2, 6: 4 }[colorType];
  const stride = w * ch;
  const raw = Buffer.alloc((stride + 1) * h);
  const prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const row = Buffer.alloc(stride);
    for (let x = 0; x < w; x++) {
      const [r, g, b] = [rgba[(y * w + x) * 4], rgba[(y * w + x) * 4 + 1], rgba[(y * w + x) * 4 + 2]];
      if (colorType === 6) rgba.copy(row, x * 4, (y * w + x) * 4, (y * w + x) * 4 + 4);
      else if (colorType === 2) row.set([r, g, b], x * 3);
      else if (colorType === 0) row[x] = r;
      else if (colorType === 4) row.set([r, 255], x * 2);
    }
    const out = Buffer.alloc(stride);
    for (let i = 0; i < stride; i++) {
      const a = i >= ch ? row[i - ch] : 0;
      const b = prev[i];
      const c = i >= ch ? prev[i - ch] : 0;
      let p;
      if (filter === 0) p = 0;
      else if (filter === 1) p = a;
      else if (filter === 2) p = b;
      else if (filter === 3) p = (a + b) >> 1;
      else {
        const pa = Math.abs(b - c),
          pb = Math.abs(a - c),
          pc = Math.abs(a + b - 2 * c);
        p = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      out[i] = (row[i] - p) & 255;
    }
    raw[y * (stride + 1)] = filter;
    out.copy(raw, y * (stride + 1) + 1);
    row.copy(prev);
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([len, body, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = colorType;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ------------------------------------------------------------------------- checks
let failures = 0;
const check = (name, ok, detail) => {
  console.log(`${ok ? "[ok]" : "[!!]"} ${name}${detail ? `  ${detail}` : ""}`);
  if (!ok) failures++;
};

// 1. the repo's own test card: a 4-bit paletted PNG
const lines = api.thumb(cardB64, "image/png", 12, 4);
const cardPalette = palette(lines.join(""));
check(
  "sixel-card.png (4-bit palette)",
  lines?.length === 4 && lines.every(l => plain(l).length === 12),
  `${lines?.length} rows x 12 cells, ${JSON.stringify(cardPalette)}`,
);
check("sixel-card.png keeps its palette", cardPalette.orange > 0 && cardPalette.cyan > 0);

// 2. synthetic RGBA: every scanline filter must decode to the same thumbnail
const W = 24,
  H = 12;
const rgba = Buffer.alloc(W * H * 4);
for (let y = 0; y < H; y++) {
  for (let x = 0; x < W; x++) {
    const [r, g, b] = y < H / 2 ? (x < W / 2 ? [247, 148, 29] : [0, 200, 255]) : [0, 190, 60];
    rgba.set([r, g, b, 255], (y * W + x) * 4);
  }
}
const base = api.thumb(png(W, H, rgba, { filter: 0 }).toString("base64"), "image/png", 12, 4);
for (const filter of [1, 2, 3, 4]) {
  const got = api.thumb(png(W, H, rgba, { filter }).toString("base64"), "image/png", 12, 4);
  check(`scanline filter ${filter}`, JSON.stringify(got) === JSON.stringify(base));
}
const synth = palette(base.join(""));
check("rgba palette survives downsampling", synth.orange > 0 && synth.cyan > 0 && synth.green > 0, JSON.stringify(synth));

// 3. the other colour types decode too
for (const colorType of [0, 2, 4]) {
  check(`colour type ${colorType}`, api.thumb(png(W, H, rgba, { colorType }).toString("base64"), "image/png", 12, 4)?.length === 4);
}

// 4. non-PNG and broken input fall back to the icon (null) instead of throwing
check("jpeg mime -> null", api.thumb(cardB64, "image/jpeg", 12, 4) === null);
check("garbage base64 -> null", api.thumb("not-base64!!", "image/png", 12, 4) === null);
check("truncated png -> null", api.thumb(cardB64.slice(0, 60), "image/png", 12, 4) === null);
check("empty -> null", api.thumb("", "image/png", 12, 4) === null);

// 5. degenerate sizes still produce exactly the requested cell grid
const tiny = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
check("1x1 png at 4x2", api.thumb(tiny, "image/png", 4, 2)?.every(l => plain(l).length === 4) === true);
check("1x1 png at 40x10", api.thumb(tiny, "image/png", 40, 10)?.every(l => plain(l).length === 40) === true);

// 6. the card's real geometry: 24x6 cells = 24x12 samples, and a 2:1 source fits it exactly
const cardLines = api.thumb(png(W, H, rgba, { filter: 0 }).toString("base64"), "image/png", 24, 6);
const cardP = palette(cardLines.join(""));
check(
  "24x6 (card size) keeps all three colours",
  cardLines.length === 6 && cardLines.every(l => plain(l).length === 24) && cardP.orange > 0 && cardP.cyan > 0 && cardP.green > 0,
  JSON.stringify(cardP),
);

// 7. a 1:1 source is center-cropped into the wider box, never stretched
const square = Buffer.alloc(W * W * 4);
for (let y = 0; y < W; y++) for (let x = 0; x < W; x++) square.set([247, 148, 29, 255], (y * W + x) * 4);
const squareLines = api.thumb(png(W, W, square, { filter: 0 }).toString("base64"), "image/png", 24, 6);
check(
  "1:1 source crops into the 2:1 card",
  squareLines?.length === 6 && squareLines.every(l => plain(l).length === 24) && palette(squareLines.join("")).orange > 0,
);

// 8. webp — what omp actually stores for a pasted clipboard image — needs the async Bun path
const webpB64 = Buffer.from(await new Bun.Image(png(W, H, rgba, { filter: 0 })).webp().bytes()).toString("base64");
let repainted = false;
const owner = { requestRender: () => (repainted = true) };
const firstPass = api.thumb(webpB64, "image/webp", 12, 4, owner);
let secondPass = null;
for (let i = 0; i < 40 && !secondPass; i++) {
  await Bun.sleep(25);
  secondPass = api.thumb(webpB64, "image/webp", 12, 4, owner);
}
check("webp -> null, then thumbnail after repaint", firstPass === null && secondPass?.length === 4, `repaint=${repainted}`);
check("webp thumbnail has the png shape", secondPass.every((l, i) => plain(l).length === plain(base[i]).length));
const webpPalette = palette(secondPass.join(""));
check("webp palette", webpPalette.orange > 0 && webpPalette.cyan > 0 && webpPalette.green > 0, JSON.stringify(webpPalette));

console.log(failures === 0 ? "\nPASS" : `\nFAIL (${failures})`);
process.exit(failures === 0 ? 0 : 1);
