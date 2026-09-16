/**
 * The patcher edits a vendored, minified bundle, so its anchors are the whole risk: an anchor that
 * silently stops matching turns an omp upgrade into an unpatched bundle, and one that matches the
 * wrong thing wires the patch to a class that happens to share a name. These tests pin both ends with
 * inline fixtures taken verbatim from omp 18.2.1 — small strings, never the 22 MB bundle — and check
 * the `check --json` contract install.ps1 and the extension consume.
 */
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import { MARK, PATCH_REV, patchSource, plan } from "../tools/patch-paste-images.mjs";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PATCHER = path.join(ROOT, "tools", "patch-paste-images.mjs");
const KEYS = ["ompVersion", "cliPath", "patched", "patchRev", "stale", "reason"];

// ---------------------------------------------------------------- 18.2.1 fixtures, verbatim

const BAND =
  '#n(e,t,s){if(t&&Rt.imageProtocol==="\\x1B_G"&&jK().unicodePlaceholders){let i=this.#o(e);if(i){let a=this.budget,l=a.acquireId(`chip:${i.mimeType}:${i.data.length}:${i.data.slice(0,32)}`);if(!a.observe(l)){let u=zK(i.data,{widthPx:t.width,heightPx:t.height},{maxWidthCells:ck,maxHeightCells:Imt,imageId:l,includeTransmit:a.shouldTransmit(l)});if(u?.transmit)a.enqueueTransmit(l,u.transmit);if(u?.lines)return this.#r(u.lines)}}}let n=b.symbol(s==="video"?"chip.video":"chip.image"),o=ck-pe(n),r=" ".repeat(Math.floor(o/2))+b.fg("muted",n)+" ".repeat(Math.ceil(o/2));return[" ".repeat(ck),r," ".repeat(ck)," ".repeat(ck)]}';

const CARD_FRAME = 'return[this.#t(t,i,"top"),...o.map((a)=>r+a+r),this.#t(t,n,"bottom")]}';

const CARD_SIZE =
  'render(e){let t=this.editor.composerChips();if(t.length===0)return[];let s=["","","","","",""],n=" ".repeat(hdo),o=0;for(let r of t){if(o+gdo>e)break;let i=this.#e(r);for(let a=0;a<s.length;a++)s[a]+=(o>0?n:"")+i[a];o+=(o>0?hdo:0)+gdo}return s}';

const CHIP_METHOD = "#e(e){let t=j8(e.kind,e.n),";

const TRANSCRIPT = 'this.ctx.chatContainer.addChild(r)}break}case"assistant"';

// The helper the composer reads its caps through. 18.2.1 added the `?? Lr(...)` default and renamed
// the derivation `Ha` → `tl`; both names are irrelevant to the patch, which needs only the function.
const IMAGE_OPTIONS_NEW =
  'function sB(){let e=tl()?ke:void 0,t=e?.get("tui.maxInlineImageColumns")??Lr("tui.maxInlineImageColumns"),s=Math.max(0,e?.get("tui.maxInlineImageRows")??Lr("tui.maxInlineImageRows"))}';
// The 18.2.0 shape: no fallback, different minifier names again.
const IMAGE_OPTIONS_OLD =
  'function Ha(){let e=Ib()?ke:void 0,t=e?.get("tui.maxInlineImageColumns"),s=Math.max(0,e?.get("tui.maxInlineImageRows"))}';
// Neither `e` nor `t`, and `var` rather than `let`: the only invariant is the second read coming off
// the variable the first one produced.
const IMAGE_OPTIONS_VAR = 'function qa(){var n=Ib()?ke:void 0,o=n?.get("tui.maxInlineImageColumns")}';

function fixture({ imageOptions = IMAGE_OPTIONS_NEW, imageExports = "var wan={};F(wan,{Image:()=>Gh});" } = {}) {
  return [
    "// @bun",
    "var Zb={};F(Zb,{AttachmentChipsBand:()=>Yb});",
    'var ck=12,Imt=4,gdo,hdo=2,ads="\\x1B[39m";',
    BAND,
    CARD_FRAME,
    CARD_SIZE,
    CHIP_METHOD,
    TRANSCRIPT,
    imageOptions,
    'if(Rt.imageProtocol==="\\x1BPq")try{',
    'var _th=b.symbol("boxRound.vertical");',
    imageExports,
    "var Kun={};F(Kun,{Spacer:()=>Ee});",
    "Nin={widthPx:9,heightPx:18};",
  ].join("\n");
}

function runPatcher(args) {
  try {
    return { code: 0, stdout: execFileSync(process.execPath, [PATCHER, ...args], { encoding: "utf8" }) };
  } catch (err) {
    return { code: err.status ?? 1, stdout: String(err.stdout ?? ""), stderr: String(err.stderr ?? "") };
  }
}

/** A throwaway install: `pkg/package.json` plus `pkg/dist/cli.js`, which is where the version and
 *  the bundle are read from. */
function tempInstall({ cli = "", version = "9.9.9", state } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "omp-images-test-"));
  const dist = path.join(root, "pkg", "dist");
  fs.mkdirSync(dist, { recursive: true });
  const cliPath = path.join(dist, "cli.js");
  fs.writeFileSync(cliPath, cli);
  fs.writeFileSync(path.join(root, "pkg", "package.json"), `${JSON.stringify({ name: "@oh-my-pi/pi-coding-agent", version }, null, 2)}\n`);
  if (state) fs.writeFileSync(`${cliPath}.ompimages.json`, `${JSON.stringify(state, null, 2)}\n`);
  return { cliPath, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

// ----------------------------------------------------------------------------------- aliases

test("every alias resolves by structure on the 18.2.1 fixture", () => {
  const { aliases, edits } = plan(fixture());
  assert.deepEqual(aliases, {
    cardW: "ck",
    cardH: "Imt",
    stride: "gdo",
    gap: "hdo",
    chipArg: "e",
    caps: "Rt",
    theme: "b",
    image: "Gh",
    spacer: "Ee",
    imageOptions: "sB",
    cell: "Nin",
  });
  assert.equal(edits.length, 4);
});

test("the older helper shape, and renamed variables, still resolve", () => {
  assert.equal(plan(fixture({ imageOptions: IMAGE_OPTIONS_OLD })).aliases.imageOptions, "Ha");
  assert.equal(plan(fixture({ imageOptions: IMAGE_OPTIONS_VAR })).aliases.imageOptions, "qa");
});

test("an export map that disagrees with itself is refused, not guessed", () => {
  const source = fixture({ imageExports: "var wan={};F(wan,{Image:()=>Gh});var qz={};F(qz,{Image:()=>Qz});" });
  assert.throws(() => plan(source), /cannot resolve the Image component/);
});

test("a moved anchor names the build, the pattern and the neighbourhood", () => {
  const source = fixture({ imageOptions: "function zz(){return {}}" });
  assert.throws(
    () => plan(source),
    err => {
      assert.match(err.message, /inline-image options helper/);
      assert.match(err.message, /tui\\\.maxInlineImageColumns/, "the failing pattern is printed");
      assert.match(err.message, /expected/, "the bytes around the expected location are printed");
      assert.match(err.message, /"tui\.maxInlineImageColumns"/, "and they are the real neighbourhood");
      return true;
    },
  );
});

// ------------------------------------------------------------------------------------- edits

test("one pass consumes all four anchors and injects the bundle's own identifiers", () => {
  const { source, produced } = patchSource(fixture());
  assert.deepEqual(
    produced.map(([name]) => name),
    ["band", "card-frame", "card-size", "transcript"],
  );
  assert.ok(source.includes(MARK), "the helper is injected");
  // The injected code names whatever the bundle calls these, never a literal from another build.
  assert.match(source, /new Gh\(/);
  assert.match(source, /new Ee\(1\)/);
  assert.match(source, /sB\(\)/);
  assert.match(source, /b\.fg\("toolOutput"/);
  assert.match(source, /Rt\.imageProtocol/);
  assert.match(source, /__ompPasteImages\.chip\(/);
  // Both surfaces the patch exists for: the band's icon fallback and the transcript bubble.
  assert.match(source, /_rows\[Math\.max\(0,Math\.floor\(Imt\/2\)-1\)\]=r/, "the caption from the stock fallback survives");
  assert.match(source, /imageKey:"ompimg:"/);
  assert.ok(source.length > fixture().length, "the patch adds code");
});

test("a patched bundle is refused by a second pass", () => {
  const { source } = patchSource(fixture());
  assert.throws(() => patchSource(source), /anchor 'band'/);
});

// ---------------------------------------------------------------------------- check --json

test("check --json emits the documented object and exits non-zero when unpatched", () => {
  const install = tempInstall({ cli: fixture() });
  try {
    const result = runPatcher(["check", "--json", "--cli", install.cliPath]);
    assert.notEqual(result.code, 0, "an unpatched bundle is not a success");
    const info = JSON.parse(result.stdout);
    assert.deepEqual(Object.keys(info), KEYS);
    assert.equal(info.ompVersion, "9.9.9");
    assert.equal(info.cliPath, install.cliPath);
    assert.equal(info.patched, false);
    assert.equal(info.patchRev, PATCH_REV);
    assert.equal(info.stale, false, "nothing was applied, so nothing is stale");
    assert.equal(info.reason, "not patched");
  } finally {
    install.cleanup();
  }
});

test("check --json separates 'not patched' from 'cannot be patched'", () => {
  const install = tempInstall({ cli: "console.log('a build the anchors do not know');\n" });
  try {
    const result = runPatcher(["check", "--json", "--cli", install.cliPath]);
    assert.notEqual(result.code, 0);
    const info = JSON.parse(result.stdout);
    assert.equal(info.patched, false);
    assert.match(info.reason, /^unsatisfiable: /, "an apply here cannot work, and the caller is told");
  } finally {
    install.cleanup();
  }
});

test("check --json reports a bundle patched by another build as stale", () => {
  const install = tempInstall({ cli: `var x=1;${MARK}var y=2;`, version: "18.2.1" });
  try {
    fs.writeFileSync(
      `${install.cliPath}.ompimages.json`,
      JSON.stringify({ ompVersion: "18.2.0", cliSha256: "0".repeat(64), patchRev: PATCH_REV, appliedAt: "2026-01-01T00:00:00.000Z" }),
    );
    const result = runPatcher(["check", "--json", "--cli", install.cliPath]);
    assert.notEqual(result.code, 0, "a bundle applied to another build is not current");
    const info = JSON.parse(result.stdout);
    assert.deepEqual(Object.keys(info), KEYS);
    assert.equal(info.patched, true);
    assert.equal(info.stale, true);
    assert.match(info.reason, /applied to omp 18\.2\.0, the bundle is omp 18\.2\.1/);
    assert.match(info.reason, /bytes changed since it was applied/);
  } finally {
    install.cleanup();
  }
});

test("check --json is a success only when the state file matches the bundle byte for byte", () => {
  const cli = `var x=1;${MARK}var y=2;`;
  const install = tempInstall({ cli, version: "18.2.1" });
  try {
    fs.writeFileSync(
      `${install.cliPath}.ompimages.json`,
      JSON.stringify({
        ompVersion: "18.2.1",
        cliSha256: crypto.createHash("sha256").update(Buffer.from(cli, "utf8")).digest("hex"),
        patchRev: PATCH_REV,
        appliedAt: "2026-01-01T00:00:00.000Z",
      }),
    );
    const result = runPatcher(["check", "--json", "--cli", install.cliPath]);
    assert.equal(result.code, 0, result.stderr);
    const info = JSON.parse(result.stdout);
    assert.deepEqual(Object.keys(info), KEYS);
    assert.deepEqual(
      { patched: info.patched, stale: info.stale, reason: info.reason },
      { patched: true, stale: false, reason: "" },
    );
  } finally {
    install.cleanup();
  }
});

test("check --json answers in the documented shape when there is no bundle to read", () => {
  const missing = path.join(os.tmpdir(), "omp-images-test-absent", "dist", "cli.js");
  const result = runPatcher(["check", "--json", "--cli", missing]);
  assert.notEqual(result.code, 0);
  const info = JSON.parse(result.stdout);
  assert.deepEqual(Object.keys(info), KEYS);
  assert.equal(info.patched, false);
  assert.match(info.reason, /^unsatisfiable: /, "callers must not retry an apply that cannot work");
});
