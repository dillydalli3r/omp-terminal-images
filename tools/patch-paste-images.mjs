/**
 * Show pasted images as pictures on terminals that only speak SIXEL.
 *
 *   bun tools/patch-paste-images.mjs status          # is the patch applied, and is it current?
 *   bun tools/patch-paste-images.mjs check [--json]  # one machine-readable verdict, non-zero exit when not current
 *   bun tools/patch-paste-images.mjs apply           # patch the installed omp bundle
 *   bun tools/patch-paste-images.mjs revert          # restore the backup
 *
 * Why a patch and not an extension: the composer attachment band is built
 * internally and hard-gated to Kitty Unicode placeholders
 * (pi-coding-agent/src/modes/components/attachment-chips.ts:118-155), and pasted
 * image bytes are dropped before the transcript user message is constructed
 * (src/modes/utils/ui-helpers.ts:104-124 `imageLinksForMessage`). The extension
 * API only renders extension-owned messages (src/extensibility/extensions/types.ts),
 * so neither surface is reachable from an extension. All TUI code ships minified
 * inside `@oh-my-pi/pi-coding-agent/dist/cli.js`, which is what `omp` runs, so the
 * patch is applied there.
 *
 * The patch adds two things, each wrapped in try/catch so a mismatch degrades to
 * the stock behaviour instead of breaking the TUI:
 *   1. transcript — a user/developer message that carries images gets real `Image`
 *      children (the same component tool results use, which draws SIXEL on
 *      Windows Terminal).
 *   2. composer band — the icon fallback becomes the image itself, drawn by that
 *      same `Image` component and boxed in with `│` at each edge. Half-block text
 *      cells were the first attempt and are a dead end: one half block covers one
 *      cell quadrant, so the best a thumbnail can be is an 8x8 px mosaic. The box
 *      is built around the raster rather than by the component because the raster
 *      is cursor-addressed — see the `card-frame` edit.
 *
 * UPDATE HAZARD: this edits a vendored, minified bundle. Any omp upgrade
 * overwrites it (silently reverting the patch); re-run `apply` after an upgrade —
 * it either re-patches or refuses once an anchor has moved. `revert` restores the
 * pristine file from `<cli>.bak-ompimages`. `apply` also records what it wrote in
 * `<cli>.ompimages.json`, so a bundle that was overwritten or replaced by a newer
 * build is reported as stale instead of passing as patched.
 */
import { spawnSync } from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";

const MARK = "/*omp-terminal-images:paste v1*/";
const BACKUP_SUFFIX = ".bak-ompimages";
const STATE_SUFFIX = ".ompimages.json";

/**
 * Bumped whenever any alias or edit regex below changes — not when the injected code
 * changes, which the file's own `MARK` covers. The state file records the revision
 * that wrote it, so a bundle patched by an older anchor set reports as stale and is
 * re-applied instead of being trusted.
 */
const PATCH_REV = 2;

/** The omp build the last inspected bundle belongs to; used to label failures. */
let OMP_VERSION = "unknown";

/** Same install roots tools/lib.mjs probes, plus the coding-agent package. */
function candidateCliPaths() {
  const home = os.homedir();
  const appData = process.env.APPDATA ?? path.join(home, "AppData", "Roaming");
  const localAppData = process.env.LOCALAPPDATA ?? path.join(home, "AppData", "Local");
  const roots = [
    process.env.OMP_PI_CODING_AGENT,
    path.join(home, ".bun", "install", "global", "node_modules", "@oh-my-pi", "pi-coding-agent"),
    path.join(appData, "npm", "node_modules", "@oh-my-pi", "pi-coding-agent"),
    path.join(localAppData, "omp", "node_modules", "@oh-my-pi", "pi-coding-agent"),
    path.join(home, ".omp", "plugins", "node_modules", "@oh-my-pi", "pi-coding-agent"),
  ].filter(Boolean);
  const profiles = path.join(home, ".omp", "profiles");
  if (fs.existsSync(profiles)) {
    for (const entry of fs.readdirSync(profiles)) {
      roots.push(path.join(profiles, entry, "node_modules", "@oh-my-pi", "pi-coding-agent"));
    }
  }
  return [...new Set(roots)].map(root => path.join(root, "dist", "cli.js")).filter(p => fs.existsSync(p));
}

function resolveCli(explicit) {
  if (explicit) {
    if (!fs.existsSync(explicit)) throw new Error(`--cli not found: ${explicit}`);
    return path.resolve(explicit);
  }
  const found = candidateCliPaths();
  if (found.length === 0) {
    throw new Error(
      "could not find @oh-my-pi/pi-coding-agent/dist/cli.js. Pass --cli <path> or set OMP_PI_CODING_AGENT.",
    );
  }
  return found[0];
}

/** The version of the package the bundle belongs to. */
function ompVersionOf(cliPath) {
  try {
    const manifest = JSON.parse(fs.readFileSync(path.join(path.dirname(cliPath), "..", "package.json"), "utf8"));
    OMP_VERSION = typeof manifest.version === "string" ? manifest.version : "unknown";
  } catch {
    OMP_VERSION = "unknown";
  }
  return OMP_VERSION;
}

/** The state file `apply` writes and `check`/`status` compare against. */
function stateFile(cliPath) {
  return `${cliPath}${STATE_SUFFIX}`;
}

function readState(cliPath) {
  try {
    const state = JSON.parse(fs.readFileSync(stateFile(cliPath), "utf8"));
    return typeof state === "object" && state !== null ? state : null;
  } catch {
    return null;
  }
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

// --------------------------------------------------------------- injected code

/**
 * Composer preview caps, in cells. Sharpness no longer depends on these — the
 * raster is drawn at native resolution — so they only bound the footprint: a 2:1
 * image lands at 48x12 cells = 432x216 px, a 16:9 screenshot at 42x12.
 */
const MAX_COLS = 56;
const MAX_ROWS = 12;

/**
 * Injected helper. The composer attachment preview is drawn by the same Image
 * component the transcript draws tool images with, so it goes through the
 * terminal's own protocol (SIXEL on Windows Terminal) at native resolution
 * instead of being resampled into half-block text cells — a half block is one
 * cell quadrant, which caps the preview at an 8x8 px mosaic.
 *
 * One Image instance per (image, width) stays alive, so `render()` is a cache hit
 * on every repaint and the terminal payload is encoded once per size.
 */
function helper(a) {
  return `${MARK}
globalThis.__ompPasteImages=(function(){
  var CACHE=new Map();
  function chip(base64,mimeType,cols){
    if(!base64||!mimeType||!(cols>0))return null;
    var key=cols+"|"+mimeType+"|"+base64.length+"|"+base64.slice(0,32);
    var img=CACHE.get(key);
    if(img===void 0){
      if(CACHE.size>16)CACHE.clear();
      img=new ${a.image}(base64,mimeType,{fallbackColor:function(_x){return ${a.theme}.fg("toolOutput",_x);}},{maxWidthCells:cols+2,maxHeightCells:${MAX_ROWS}});
      CACHE.set(key,img);
    }
    try{return img.render(cols+2);}catch(_e){if(process.env.OMP_PASTE_DEBUG)console.error("omp-paste-images: "+_e);return null;}
  }
  return {chip:chip};
})();
`;
}

/**
 * Failure text has to carry enough to diagnose a build nobody has in hand: what was
 * being looked for, which omp it is, the pattern, and the bytes around where the
 * thing was expected. A one-line refusal turns every omp release into a bisect.
 */
function fail(what, re, witness, source, detail) {
  const at = witness ? source.indexOf(witness) : -1;
  const near =
    at < 0
      ? `"${witness}" is absent too`
      : JSON.stringify(source.slice(Math.max(0, at - 100), at + 100));
  return new Error(
    `cannot resolve ${what}${detail ? ` (${detail})` : ""} — this omp build is not one this patch understands\n` +
      `     omp        ${OMP_VERSION}\n` +
      `     pattern    ${re}\n` +
      `     expected   ${near}\n` +
      "     Nothing was written. Reinstall omp for a matching build, or update tools/patch-paste-images.mjs.",
  );
}

/**
 * Anchors are regexes and every identifier the injected code needs is captured out
 * of the bundle rather than hard-coded. Both the minifier's aliases and the
 * bundle's shape change between omp releases — 18.1.22's `Ib`/`Apt`/`tlo`/`b`/
 * `Ct`/`Ee`/`WH` are 18.2.0's `jk`/`fdt`/`Llo`/`k`/`kt`/`xe`/`hB`, and 18.2.0's
 * `Ha` is 18.2.1's `tl` — and a literal anchor silently degenerates into an
 * unpatched bundle on the next upgrade. A regex that stops matching makes `apply`
 * refuse to write instead. Where a name is exported from several modules the same
 * way, every match has to agree on the name: patching whichever module happens to
 * come first is a wrong-class bug nothing would catch at boot.
 */
function resolveAliases(source) {
  // The band class is named by its module export map, which is public API and not
  // minified — the same string the stock UI shows in a stack trace.
  const bandAt = source.indexOf("AttachmentChipsBand:()=>");
  if (bandAt < 0) {
    throw fail("the attachment band module", /AttachmentChipsBand:\(\)=>/, "boxRound.", source, "no match");
  }
  const region = source.slice(bandAt, bandAt + 6000);

  // Invariant: the four module-scope card geometry vars in declaration order —
  // interior width, interior rows, the (unassigned) stride = width + 2, and the gap.
  // The stock values are facts about the layout, not minifier output, so they stay
  // literal here; the names do not.
  const consts = /var ([\w$]+)=12,([\w$]+)=4,([\w$]+),([\w$]+)=2,/.exec(region);
  if (!consts) {
    throw fail(
      "the attachment card geometry constants",
      /var ([\w$]+)=12,([\w$]+)=4,([\w$]+),([\w$]+)=2,/,
      "composerChips()",
      source,
      "no match",
    );
  }
  // Invariant: the class's private one-chip method — a single parameter, and a body
  // that starts by deriving the chip's caption from `param.kind` and `param.n`. The
  // method name and the parameter name are both captured.
  const chipMethod = /#([\w$]+)\(([\w$]+)\)\{let [\w$]+=[\w$]+\(\2\.kind,\2\.n\),/.exec(region);
  if (!chipMethod) {
    throw fail(
      "the attachment chip method",
      /#([\w$]+)\(([\w$]+)\)\{let [\w$]+=[\w$]+\(\2\.kind,\2\.n\),/,
      "chip.image",
      source,
      "no match",
    );
  }

  const aliases = {
    cardW: consts[1], // module-scope interior width, stock 12
    cardH: consts[2], // module-scope interior rows, stock 4
    stride: consts[3], // = cardW + 2, assigned once at module init
    gap: consts[4], // blank columns between two cards
    chipArg: chipMethod[2], // the chip parameter, used to tell a paste from an image
    // Invariant: a `.imageProtocol === "\x1BPq"` comparison whose truthy branch is a
    // `try` — the capabilities object, found by the SIXEL DCS introducer the compare
    // is about (a literal no minifier rewrites) instead of the object's name. The
    // comparison with the `try` behind it is unique; without the `try` it is not
    // (5 hits, only one of them the capabilities object).
    caps: pick(source, /\(([\w$]+)\.imageProtocol==="\\x1BPq"\)try\{/, "the terminal capabilities object", '.imageProtocol==="\\x1BPq")try'),
    // Invariant: whatever object the attachment band calls `.symbol("boxRound.*")` on
    // for its border glyphs — the theme. `symbol` and `boxRound.` are public names.
    theme: pick(source, /([\w$]+)\.symbol\("boxRound\./, "the theme object", '"boxRound.'),
    // Invariant: a binding named exactly `Image`/`Spacer` in an export map — the
    // leading boundary keeps `resizeImage`/`createVideoPreviewImage` out. Both are
    // re-exported by several modules under the same name, which is why `pick`
    // requires every match to agree rather than taking the first.
    image: pick(source, /[,{]Image:\(\)=>([\w$]+)/, "the Image component", "Image:()=>"),
    spacer: pick(source, /[,{]Spacer:\(\)=>([\w$]+)/, "the Spacer component", "Spacer:()=>"),
    // Invariant: a zero-argument function that reads the literal
    // "tui.maxInlineImageColumns" off the variable it just derived, whatever that
    // derivation is. 18.2.0 read it through `Ha()?;` 18.2.1 through `tl()` with a
    // `?? Lr(...)` default behind it — both match, and neither name is spelled here.
    // The second read must come off the same variable as the first (\2).
    imageOptions: pick(
      source,
      /function ([\w$]+)\(\)\{(?:var|let|const) ([\w$]+)=[\w$]+\(\)\?[\w$]+:void 0,[\w$]+=\2\?\.get\("tui\.maxInlineImageColumns"\)/,
      "the inline-image options helper",
      '"tui.maxInlineImageColumns"',
    ),
    // Invariant: the literal `{widthPx:<n>,heightPx:<n>}` — the terminal cell size in
    // px, one module-scope object, read again by every image render. The `widthPx`/
    // `heightPx` keys are public; the object's name is captured. (A getter/setter
    // pair is not unique — several modules have one — so anchor on the initializer.)
    cell: pick(source, /([\w$]+)=\{widthPx:\d+,heightPx:\d+\};/, "the terminal cell size", "{widthPx:"),
  };
  // A dropped alias would interpolate as `undefined` and silently disable a patch
  // through the injected try/catch, so every one an edit uses has to be present.
  for (const key of Object.keys(aliases)) {
    if (typeof aliases[key] !== "string") throw new Error(`alias '${key}' resolved to nothing`);
  }
  return aliases;
}

/** First capture, and the capture must be the same name in every match. */
function pick(source, re, what, witness) {
  const found = [...source.matchAll(new RegExp(re.source, `${re.flags.replace("g", "")}g`))];
  const names = new Set(found.map(m => m[1]));
  if (names.size !== 1) {
    throw fail(
      what,
      re,
      witness,
      source,
      names.size === 0 ? "no match" : `${names.size} different matches: ${[...names].join(", ")}`,
    );
  }
  return found[0][1];
}

/** Every edit, with the regex that must match exactly once in the pristine bundle. */
function buildEdits(a) {
  return [
    {
      // Composer band: the icon fallback (`#n` of AttachmentChipsBand) becomes the
      // image itself for every protocol except Kitty (which composes its own
      // placeholders), and the fallback grows from the stock fixed 4 rows to the
      // frame's.
      name: "band",
      witness: "chip.image",
      re: /#n\(([\w$]+),([\w$]+),([\w$]+)\)\{([\s\S]{0,900}?)return\[" "\.repeat\(([\w$]+)\),([\w$]+)," "\.repeat\(\5\)," "\.repeat\(\5\)\]\}/,
      out: m =>
        `#n(${m[1]},${m[2]},${m[3]}){${m[4]}` +
        `if(${a.caps}.imageProtocol&&${a.caps}.imageProtocol!=="\\x1B_G"){` +
        `var _l=globalThis.__ompPasteImages&&globalThis.__ompPasteImages.chip(${m[1]}.data,${m[1]}.mimeType,${a.cardW});` +
        `if(_l&&_l.length)return _l}` +
        `var _rows=Array(${a.cardH}).fill(" ".repeat(${a.cardW}));_rows[Math.max(0,Math.floor(${a.cardH}/2)-1)]=${m[6]};return _rows}`,
    },
    {
      // Draw the pasted image as a real box: `│` on both sides at the exact edge of
      // the raster, corners above and below.
      //
      // The raster cannot simply sit inside a bordered row, because it is
      // cursor-addressed: the sequence saves the cursor, moves up, paints a raster
      // that runs right and up from where it starts, then restores the cursor to the
      // saved cell. Text written after it would therefore land back on the image's
      // first column. So the interior rows are built here instead of taken from the
      // component: `│` + cells + `│` for every row, and on the last one the sequence
      // is followed by an explicit cursor-forward past the raster before the closing
      // `│` is written. The raster starts one cell in, so it never touches either
      // border, and it paints upward over the spaces of the rows above it, which
      // leaves their borders standing.
      //
      // The frame width comes from the raster the encoder actually emitted, not from
      // the width that was asked for: the encoder refits to `maxHeightCells`, so a
      // 2:1 image requested at 56 cells comes back 48 wide, and `#t` adds the two
      // corners on top of the width it is handed.
      name: "card-frame",
      witness: ',"top"),',
      re: /return\[this\.#([\w$]+)\(([\w$]+),([\w$]+),"top"\),\.\.\.([\w$]+)\.map\(\(([\w$]+)\)=>([\w$]+)\+\5\+\6\),this\.#\1\(\2,([\w$]+),"bottom"\)\]\}/,
      out: m => {
        const [border, ref, caption, interior, param, side, size] = m.slice(1);
        const head = `return[this.#${border}(${ref},${caption},"top"),`;
        const tail = `,this.#${border}(${ref},${size},"bottom")];`;
        return (
          `if(${a.caps}.imageProtocol&&${a.caps}.imageProtocol!=="\\x1B_G"&&${a.chipArg}.kind!=="paste"){` +
          `var _j0=${a.cardW},_L=${interior},_R=_L.length,_d=_R?_L[_R-1]:"",_s=_d?_d.indexOf("\\x1BP"):-1;` +
          `if(_s>=0){` +
          `var _mt=/\\x1BP[0-9;]*q"1;1;(\\d+);/.exec(_d),_C=_mt?Math.round(+_mt[1]/${a.cell}.widthPx):0;` +
          `if(_C>1){` +
          `${a.cardW}=_C;` +
          `var _dcs=_d.slice(_s);if(_dcs.slice(-2)==="\\x1B8")_dcs=_dcs.slice(0,-2);` +
          `var _sp=" ".repeat(_C),_o=[],_i;` +
          `for(_i=1;_i<_R;_i++)_o.push(${side}+_sp+${side});` +
          `_o.push(${side}+(_R>1?"\\x1B7\\x1B["+(_R-1)+"A":"\\x1B7")+_dcs+"\\x1B8\\x1B["+_C+"C"+${side});` +
          // A shorter chip is padded above its raster (which ends on its own last
          // row), so every box in the band keeps the same height.
          `while(_o.length<${a.cardH})_o.unshift(${side}+_sp+${side});` +
          `var _card=[this.#${border}(${ref},${caption},"top"),..._o,this.#${border}(${ref},${size},"bottom")];` +
          `${a.cardW}=_j0;return _card}}}` +
          `${head}...${interior}.map((${param})=>${side}+${param}+${side})${tail}}`
        );
      },
    },
    {
      // Card geometry. Stock is a fixed 12x4 cells. Instead the band sizes one card
      // per frame from the first attached image, asking the Image component itself
      // for the row count so the frame matches the raster exactly. `cardW`/`cardH`/
      // `stride` are module-scope vars the class already reads, so `render()` just
      // rewrites them before building the frame — every downstream use (`#t`
      // borders, `#e` caption, `#n` image, `#r` centering, `#i` paste text) picks
      // the new size up for free.
      //
      // Simplification: one geometry per band, taken from the first image chip, so a
      // band mixing a text paste and an image sizes both the same way.
      name: "card-size",
      witness: "composerChips()",
      re: /render\(e\)\{let t=this\.editor\.composerChips\(\);if\(t\.length===0\)return\[\];let s=\["","","","","",""\],n=" "\.repeat\(([\w$]+)\),o=0;for\(let r of t\)\{if\(o\+([\w$]+)>e\)break;let i=this\.#([\w$]+)\(r\);for\(let a=0;a<s\.length;a\+\+\)s\[a\]\+=\(o>0\?n:""\)\+i\[a\];o\+=\(o>0\?\1:0\)\+\2\}return s\}/,
      out: m =>
        `render(e){let t=this.editor.composerChips();if(t.length===0)return[];` +
        `var _W=${a.cardW},_H=${a.cardH};` +
        `if(${a.caps}.imageProtocol&&${a.caps}.imageProtocol!=="\\x1B_G"){` +
        `var _cols=Math.max(12,Math.min(${MAX_COLS},e-${m[1]}-2));` +
        `for(var c of t){if(!c||c.kind==="paste")continue;` +
        `var _l=globalThis.__ompPasteImages&&globalThis.__ompPasteImages.chip(c.image.data,c.image.mimeType,_cols);` +
        `if(!_l||!_l.length)continue;_W=_cols;if(_l.length>_H)_H=_l.length}}` +
        `${a.cardW}=_W,${a.cardH}=_H,${a.stride}=${a.cardW}+2;` +
        `let s=Array(${a.cardH}+2).fill(""),n=" ".repeat(${m[1]}),o=0;for(let r of t){if(o+${m[2]}>e)break;let i=this.#${m[3]}(r);` +
        `for(let a=0;a<s.length;a++)s[a]+=(o>0?n:"")+i[a];o+=(o>0?${m[1]}:0)+${m[2]}}return s}`,
    },
    {
      // Transcript: give user/developer messages the same Image children tool
      // results get (that component draws SIXEL on Windows Terminal).
      name: "transcript",
      witness: 'case"assistant"',
      re: /this\.ctx\.chatContainer\.addChild\(r\)\}break\}case"assistant"/,
      out: () =>
        "this.ctx.chatContainer.addChild(r)}" +
        MARK +
        "try{" +
        "var _c=Array.isArray(e.content)?e.content:[];" +
        "for(var _i=0;_i<_c.length;_i++){" +
        "var _b=_c[_i];" +
        `if(_b&&_b.type==="image"&&_b.data&&_b.mimeType&&${a.caps}.imageProtocol){` +
        `this.ctx.chatContainer.addChild(new ${a.spacer}(1));` +
        `this.ctx.chatContainer.addChild(new ${a.image}(_b.data,_b.mimeType,{fallbackColor:function(_x){return ${a.theme}.fg("toolOutput",_x);}},Object.assign({},${a.imageOptions}(),{imageKey:"ompimg:"+(e.timestamp||0)+":"+_i})));` +
        "}" +
        "}" +
        '}catch(_e){if(process.env.OMP_PASTE_DEBUG)console.error("omp-paste-images: "+_e);}' +
        'break}case"assistant"',
    },
  ];
}

function countMatches(haystack, re) {
  const global = new RegExp(re.source, `${re.flags.replace("g", "")}g`);
  return (haystack.match(global) ?? []).length;
}

/** Resolve aliases and confirm every anchor matches exactly once. */
function plan(source) {
  const aliases = resolveAliases(source);
  const edits = buildEdits(aliases);
  for (const { name, re, witness } of edits) {
    const n = countMatches(source, re);
    if (n !== 1) throw fail(`anchor '${name}'`, re, witness, source, `${n} matches`);
  }
  return { aliases, edits };
}

function injectHelper(source, aliases) {
  const at = source.indexOf("// @bun");
  if (at < 0) throw new Error("bundle head not recognised (no '// @bun')");
  const nl = source.indexOf("\n", at);
  return source.slice(0, nl + 1) + helper(aliases) + source.slice(nl + 1);
}

/**
 * The patch as one pure string -> string step, so `apply` and the tests run the same
 * code. Every replacement is kept verbatim: a replace that quietly ate a neighbour is
 * caught by `regionsMissing` before anything reaches disk.
 */
function patchSource(source) {
  const { aliases, edits } = plan(source);
  const produced = [];
  let out = injectHelper(source, aliases);
  for (const edit of edits) {
    out = out.replace(edit.re, (...m) => {
      const text = edit.out(m);
      produced.push([edit.name, text]);
      return text;
    });
  }
  return { source: out, produced };
}

/** The written bundle must still carry the helper and all four patched regions. */
function regionsMissing(source, produced) {
  if (!source.includes(MARK)) return "the injected helper is not in the bundle";
  for (const [name, text] of produced) {
    if (!source.includes(text)) return `the '${name}' edit is not in the bundle`;
  }
  return null;
}

/** Load the patched bundle once and confirm it still boots. */
function selfTest(cliPath) {
  const proc = spawnSync("bun", [cliPath, "--version"], { encoding: "utf8", timeout: 120000 });
  const out = `${proc.stdout ?? ""}${proc.stderr ?? ""}`;
  if (proc.error) return { ok: false, detail: proc.error.message };
  if (proc.status !== 0) return { ok: false, detail: out.trim().slice(-400) };
  const version = out.match(/omp\/\d+\.\d+\.\d+/);
  if (!version) return { ok: false, detail: `unexpected --version output: ${out.trim().slice(-200)}` };
  return { ok: true, detail: version[0] };
}

// ------------------------------------------------------------------- commands

/**
 * What is true of the bundle right now: patched or not, and whether the state file
 * still describes it. A bundle patched by an older revision, or one whose bytes no
 * longer match what `apply` wrote, is stale — the case an omp upgrade produces, and
 * the one that used to pass silently as "patched, nothing to do".
 */
function inspect(cliPath) {
  const raw = fs.readFileSync(cliPath, "latin1");
  const ompVersion = ompVersionOf(cliPath);
  const patched = raw.includes(MARK);
  const state = readState(cliPath);
  const reasons = [];
  if (state) {
    if (state.ompVersion !== ompVersion) {
      reasons.push(`applied to omp ${state.ompVersion}, the bundle is omp ${ompVersion}`);
    }
    if (state.patchRev !== PATCH_REV) {
      reasons.push(`applied by patch rev ${state.patchRev}, this patcher writes rev ${PATCH_REV}`);
    }
    if (patched && state.cliSha256 !== sha256(cliPath)) reasons.push("cli.js bytes changed since it was applied");
    if (!patched) reasons.push("not patched, and the state file is left over from an earlier apply");
  } else if (patched) {
    reasons.push(`patched with no ${path.basename(stateFile(cliPath))} recording which build it came from`);
  }

  // Anchors always describe the pristine bundle: the patched one no longer contains
  // them by construction.
  const backup = `${cliPath}${BACKUP_SUFFIX}`;
  const pristine = fs.existsSync(backup) ? fs.readFileSync(backup, "latin1") : patched ? null : raw;
  let anchorError = null;
  if (pristine !== null) {
    try {
      plan(pristine);
    } catch (err) {
      anchorError = err.message;
    }
  }
  return {
    ompVersion,
    cliPath,
    patched,
    patchRev: PATCH_REV,
    stale: reasons.length > 0,
    reason: reasons.join("; "),
    anchorError,
    state,
  };
}

function status(cliPath) {
  const info = inspect(cliPath);
  const backup = `${cliPath}${BACKUP_SUFFIX}`;
  console.log(`cli        ${cliPath}`);
  console.log(`omp        ${info.ompVersion}`);
  console.log(`patched    ${info.patched ? "yes" : "no"}`);
  console.log(`backup     ${fs.existsSync(backup) ? backup : "none"}`);
  console.log(
    `state      ${info.state ? `${stateFile(cliPath)} (rev ${info.state.patchRev}, omp ${info.state.ompVersion}, applied ${info.state.appliedAt})` : "none"}`,
  );
  console.log(`patchRev   ${PATCH_REV}${info.state && info.state.patchRev !== PATCH_REV ? " (stale)" : ""}`);
  if (info.stale) console.log(`stale      yes — ${info.reason}`);
  if (info.anchorError) {
    console.error(`[!!] ${info.anchorError}`);
    return 1;
  }
  let source = fs.readFileSync(cliPath, "latin1");
  if (info.patched) {
    if (!fs.existsSync(backup)) {
      console.log("anchor     — no backup, so the pristine bundle the anchors describe is gone");
      console.log("[ok] this bundle is patched; reinstall omp to get a checkable pristine copy back");
      return 0;
    }
    source = fs.readFileSync(backup, "latin1");
  }
  const { edits } = plan(source);
  for (const { name, re } of edits) console.log(`anchor ${name.padEnd(11)}${countMatches(source, re)} match(es)`);
  console.log("[ok] this bundle is one the patch understands");
  return 0;
}

/**
 * The contract install.ps1 and the extension consume: one JSON object on stdout and a
 * non-zero exit unless the bundle is patched and current. `reason` is prose, with one
 * reserved prefix — `unsatisfiable:` means the anchors do not resolve against this
 * build, so `apply` cannot help and the caller must report instead of retrying.
 */
function check(cliPath, json) {
  const info = inspect(cliPath);
  const reason = info.anchorError
    ? `unsatisfiable: ${info.anchorError.split("\n")[0]}`
    : info.reason || (info.patched ? "" : "not patched");
  const ok = info.patched && !info.stale && !info.anchorError;
  if (json) {
    console.log(
      JSON.stringify(
        {
          ompVersion: info.ompVersion,
          cliPath: info.cliPath,
          patched: info.patched,
          patchRev: info.patchRev,
          stale: info.stale,
          reason,
        },
        null,
        2,
      ),
    );
  } else {
    console.log(`cli        ${info.cliPath}`);
    console.log(`omp        ${info.ompVersion}`);
    console.log(`patched    ${info.patched ? "yes" : "no"}`);
    console.log(`patchRev   ${info.patchRev}`);
    console.log(`stale      ${info.stale ? "yes" : "no"}`);
    if (reason) console.log(`reason     ${reason}`);
    console.log(ok ? "[ok] patched and current" : "[!!] not patched and current");
  }
  return ok ? 0 : 1;
}

/** `check` must answer in the documented shape even when there is no bundle to read. */
function checkReport(cliExplicit, json) {
  let cliPath;
  try {
    cliPath = resolveCli(cliExplicit);
  } catch (err) {
    const reason = `unsatisfiable: ${err.message}`;
    if (json) {
      console.log(
        JSON.stringify({ ompVersion: "", cliPath: "", patched: false, patchRev: PATCH_REV, stale: false, reason }, null, 2),
      );
    } else {
      console.error(`[!!] ${reason}`);
    }
    return 1;
  }
  return check(cliPath, json);
}

/** Restore the pristine bundle and forget the state; the only path back to stock. */
function restore(cliPath, backup) {
  fs.copyFileSync(backup, cliPath);
  fs.rmSync(stateFile(cliPath), { force: true });
}

function apply(cliPath) {
  const backup = `${cliPath}${BACKUP_SUFFIX}`;
  // Read before anything writes: the state file records the build this bundle belongs to,
  // and a fresh apply never goes through `inspect`.
  const ompVersion = ompVersionOf(cliPath);
  let source = fs.readFileSync(cliPath, "latin1");
  if (source.includes(MARK)) {
    if (!inspect(cliPath).stale) {
      console.log(`[--] already patched and current: ${cliPath}`);
      return 0;
    }
    // Patched by an older anchor set: re-apply from scratch rather than stack a second
    // copy of the edits on top of the first.
    if (!fs.existsSync(backup)) {
      console.error(
        `[!!] this bundle is patched by an unknown revision and there is no ${backup} to restore — reinstall omp, then apply`,
      );
      return 1;
    }
    console.log(`[--] re-applying: restoring the pristine bundle from ${backup}`);
    fs.copyFileSync(backup, cliPath);
    source = fs.readFileSync(cliPath, "latin1");
  }

  let patched;
  try {
    patched = patchSource(source);
  } catch (err) {
    console.error(`[!!] ${err.message}`);
    return 1;
  }

  if (fs.existsSync(backup)) console.log(`[--] backup already present: ${backup}`);
  else {
    fs.copyFileSync(cliPath, backup);
    console.log(`[ok] backup -> ${backup}`);
  }
  fs.writeFileSync(cliPath, patched.source, "latin1");

  const missing = regionsMissing(patched.source, patched.produced);
  if (missing) {
    restore(cliPath, backup);
    console.error(`[!!] the patched bundle is incomplete (${missing}) — restored the backup, nothing changed`);
    return 1;
  }
  const boot = selfTest(cliPath);
  if (!boot.ok) {
    restore(cliPath, backup);
    console.error(`[!!] patched bundle failed to load (${boot.detail}) — restored the backup, nothing changed`);
    return 1;
  }

  const state = { ompVersion, cliSha256: sha256(cliPath), patchRev: PATCH_REV, appliedAt: new Date().toISOString() };
  fs.writeFileSync(stateFile(cliPath), `${JSON.stringify(state, null, 2)}\n`);
  console.log(`[ok] patched ${cliPath} (omp ${ompVersion}, patch rev ${PATCH_REV}, boots as ${boot.detail})`);
  console.log(`[ok] state -> ${stateFile(cliPath)}`);
  console.log("[ok] pasted images render as pictures; re-run this after every omp upgrade");
  return 0;
}

function revert(cliPath) {
  const backup = `${cliPath}${BACKUP_SUFFIX}`;
  if (!fs.existsSync(backup)) {
    if (!fs.readFileSync(cliPath, "latin1").includes(MARK)) {
      console.log("[--] nothing to revert");
      return 0;
    }
    console.error(`[!!] bundle is patched but no backup exists at ${backup}; reinstall omp to restore it`);
    return 1;
  }
  fs.copyFileSync(backup, cliPath);
  fs.rmSync(backup);
  fs.rmSync(stateFile(cliPath), { force: true });
  console.log(`[ok] restored ${cliPath} from ${backup}`);
  return 0;
}

// ----------------------------------------------------------------------- main

const invokedDirectly =
  import.meta.main === true ||
  (process.argv[1] ? pathToFileURL(process.argv[1]).href === import.meta.url : false);

if (invokedDirectly) {
  const argv = process.argv.slice(2);
  const cliFlag = argv.indexOf("--cli");
  const cliExplicit = cliFlag >= 0 ? argv[cliFlag + 1] : process.env.OMP_CLI_JS;
  const command = argv.find(a => !a.startsWith("-") && a !== cliExplicit) ?? "status";

  let code;
  try {
    if (command === "status") code = status(resolveCli(cliExplicit));
    else if (command === "check") code = checkReport(cliExplicit, argv.includes("--json"));
    else if (command === "apply") code = apply(resolveCli(cliExplicit));
    else if (command === "revert") code = revert(resolveCli(cliExplicit));
    else {
      console.error(
        `unknown command '${command}' — use: status | check [--json] | apply | revert [--cli <path to cli.js>]`,
      );
      code = 2;
    }
  } catch (err) {
    console.error(`[!!] ${err.message}`);
    code = 1;
  }
  process.exit(code);
}

export { MARK, PATCH_REV, plan, patchSource };
