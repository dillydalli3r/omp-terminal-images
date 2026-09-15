/**
 * Show pasted images as pictures on terminals that only speak SIXEL.
 *
 *   bun tools/patch-paste-images.mjs status     # is the patch applied?
 *   bun tools/patch-paste-images.mjs apply      # patch the installed omp bundle
 *   bun tools/patch-paste-images.mjs revert     # restore the backup
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
 *   2. composer band — the icon fallback becomes a truecolor half-block ("▀")
 *      thumbnail decoded from the PNG in-process. That is protocol independent and
 *      composes inside the band's bordered card, where a cursor-addressed SIXEL
 *      sequence cannot.
 *
 * UPDATE HAZARD: this edits a vendored, minified bundle. Any omp upgrade
 * overwrites it (silently reverting the patch); re-run `apply` after an upgrade —
 * it either re-patches or refuses once an anchor has moved. `revert` restores the
 * pristine file from `<cli>.bak-ompimages`.
 */
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

const MARK = "/*omp-terminal-images:paste v1*/";
const BACKUP_SUFFIX = ".bak-ompimages";

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

// --------------------------------------------------------------- injected code

/** PNG decoder + half-block renderer. Self-contained: Buffer + one zlib import. */
const HELPER = `${MARK}
import{inflateSync as __ompInflate}from"node:zlib";
globalThis.__ompPasteImages=(function(){
  var SIG=[137,80,78,71,13,10,26,10];
  function u32(b,o){return ((b[o]<<24)|(b[o+1]<<16)|(b[o+2]<<8)|b[o+3])>>>0;}
  function decodePng(buf){
    if(buf.length<33)return null;
    for(var i=0;i<8;i++)if(buf[i]!==SIG[i])return null;
    var o=8,w=0,h=0,depth=0,color=0,idat=[],plte=null,trns=null;
    while(o+8<=buf.length){
      var len=u32(buf,o),type=String.fromCharCode(buf[o+4],buf[o+5],buf[o+6],buf[o+7]);
      var data=buf.subarray(o+8,o+8+len);
      if(type==="IHDR"){
        w=u32(data,0);h=u32(data,4);depth=data[8];color=data[9];
        if(data[10]!==0||data[11]!==0||data[12]!==0)return null;
      }else if(type==="PLTE"){plte=data;}
      else if(type==="tRNS"){trns=data;}
      else if(type==="IDAT"){idat.push(data);}
      else if(type==="IEND"){break;}
      o+=12+len;
    }
    if(!w||!h||idat.length===0)return null;
    if(w*h>40000000)return null;
    var ch={0:1,2:3,3:1,4:2,6:4}[color];
    if(!ch)return null;
    var okDepth={1:1,2:1,4:1,8:1,16:1};
    var bits;
    if(color===3){if(!plte||!okDepth[depth])return null;bits=depth;}
    else if(color===0){if(!okDepth[depth])return null;bits=depth;}
    else if(depth===8){bits=ch*8;}
    else if(depth===16){bits=ch*16;}
    else return null;
    var bpp=Math.max(1,(bits+7)>>3);
    var raw;
    try{raw=__ompInflate(Buffer.concat(idat.map(function(d){return Buffer.from(d);})));}catch(e){return null;}
    var stride=Math.ceil(w*bits/8);
    if(raw.length<(stride+1)*h)return null;
    var prev=Buffer.alloc(stride),cur=Buffer.alloc(stride),out=Buffer.alloc(w*h*4),q=0;
    for(var y=0;y<h;y++){
      var filter=raw[q++];
      if(filter>4)return null;
      for(var x=0;x<stride;x++){
        var v=raw[q+x];
        var a=x>=bpp?cur[x-bpp]:0,b=prev[x],c=x>=bpp?prev[x-bpp]:0;
        if(filter===1)v=(v+a)&255;
        else if(filter===2)v=(v+b)&255;
        else if(filter===3)v=(v+((a+b)>>1))&255;
        else if(filter===4){
          var pa=Math.abs(b-c),pb=Math.abs(a-c),pc=Math.abs(a+b-2*c);
          v=(v+(pa<=pb&&pa<=pc?a:(pb<=pc?b:c)))&255;
        }
        cur[x]=v;
      }
      q+=stride;
      for(var px=0;px<w;px++){
        var r,g,bl,al=255,k=(y*w+px)*4;
        if(depth<8){
          var bit=px*depth,shift=8-depth-(bit&7);
          var idx=(cur[bit>>3]>>shift)&((1<<depth)-1);
          if(color===3){
            if(plte.length<idx*3+3)return null;
            r=plte[idx*3];g=plte[idx*3+1];bl=plte[idx*3+2];
            if(trns&&idx<trns.length)al=trns[idx];
          }else{
            var lv=Math.round(idx*255/((1<<depth)-1));
            r=g=bl=lv;
          }
        }else if(color===3){
          var pi=cur[px];
          if(plte.length<pi*3+3)return null;
          r=plte[pi*3];g=plte[pi*3+1];bl=plte[pi*3+2];
          if(trns&&pi<trns.length)al=trns[pi];
        }else if(depth===16){
          var s16=px*bpp;
          r=cur[s16];g=ch>=3?cur[s16+2]:cur[s16];bl=ch>=3?cur[s16+4]:cur[s16];
          if(ch===4)al=cur[s16+6];
        }else{
          var s8=px*bpp;
          if(color===0){r=g=bl=cur[s8];}
          else if(color===2){r=cur[s8];g=cur[s8+1];bl=cur[s8+2];}
          else if(color===4){r=g=bl=cur[s8];al=cur[s8+1];}
          else{r=cur[s8];g=cur[s8+1];bl=cur[s8+2];al=cur[s8+3];}
        }
        out[k]=r;out[k+1]=g;out[k+2]=bl;out[k+3]=al;
      }
      var swap=prev;prev=cur;cur=swap;
    }
    return {w:w,h:h,data:out};
  }
  function sample(img,x0,y0,x1,y1){
    var r=0,g=0,b=0,n=0;
    for(var y=y0;y<y1;y++){
      var row=y*img.w;
      for(var x=x0;x<x1;x++){
        var k=(row+x)*4,a=img.data[k+3]/255;
        r+=img.data[k]*a;g+=img.data[k+1]*a;b+=img.data[k+2]*a;n++;
      }
    }
    if(!n)return [0,0,0];
    return [Math.round(r/n),Math.round(g/n),Math.round(b/n)];
  }
  function clamp(v){return v<0?0:(v>255?255:v);}
  /* Each cell is one column wide and two pixels tall, so the target aspect is
     cols : rows*2. Center-crop the source to it (thumbnails crop, they never stretch),
     and boost contrast around the crop's mean — at a few hundred samples a straight
     box average reads as grey mush. */
  function halfBlock(img,cols,rows){
    if(cols<1||rows<1)return null;
    var pxW=cols,pxH=rows*2;
    var target=pxW/pxH,src=img.w/img.h,cx0=0,cy0=0,cw=img.w,ch=img.h;
    if(src>target){cw=Math.max(1,Math.round(img.h*target));cx0=Math.floor((img.w-cw)/2);}
    else if(src<target){ch=Math.max(1,Math.round(img.w/target));cy0=Math.floor((img.h-ch)/2);}
    var mean=sample(img,cx0,cy0,cx0+cw,cy0+ch),GAIN=1.25;
    function tone(v,i){return clamp(Math.round(mean[i]+(v-mean[i])*GAIN));}
    var lines=[];
    for(var cy=0;cy<rows;cy++){
      var line="";
      for(var cx=0;cx<cols;cx++){
        var x0=cx0+Math.floor(cx*cw/pxW),x1=cx0+Math.max(Math.floor(cx*cw/pxW)+1,Math.floor((cx+1)*cw/pxW));
        var fa=cy0+Math.floor((cy*2)*ch/pxH),fb=cy0+Math.max(Math.floor((cy*2)*ch/pxH)+1,Math.floor((cy*2+1)*ch/pxH));
        var ba=cy0+Math.floor((cy*2+1)*ch/pxH),bb=cy0+Math.max(Math.floor((cy*2+1)*ch/pxH)+1,Math.floor((cy*2+2)*ch/pxH));
        if(x1>cx0+cw)x1=cx0+cw;
        if(fb>cy0+ch)fb=cy0+ch;
        if(bb>cy0+ch)bb=cy0+ch;
        var fg=sample(img,x0,fa,x1,fb),bg=sample(img,x0,ba,x1,bb);
        line+="\\u001b[38;2;"+tone(fg[0],0)+";"+tone(fg[1],1)+";"+tone(fg[2],2)+"m"+
              "\\u001b[48;2;"+tone(bg[0],0)+";"+tone(bg[1],1)+";"+tone(bg[2],2)+"m\\u2580";
      }
      lines.push(line+"\\u001b[39m\\u001b[49m");
    }
    return lines;
  }
  function debug(msg){if(process.env.OMP_PASTE_DEBUG)console.error("omp-paste-images: "+msg);}
  var CACHE=new Map();
  function keyOf(base64,mime,cols,rows){return mime+"|"+cols+"x"+rows+"|"+base64.length+"|"+base64.slice(0,24);}
  function render(base64,cols,rows){
    var img=decodePng(Buffer.from(base64,"base64"));
    return img?halfBlock(img,cols,rows):null;
  }
  return {
    /* Rendered cell rows for a pasted image, or null while unknown.
       Pasted clipboard images are normalised to WebP, which Bun decodes for us:
       the first call kicks off PNG conversion off-thread and returns null, then
       calls owner.requestRender() so the band repaints with the thumbnail. */
    thumb:function(base64,mimeType,cols,rows,owner){
      try{
        if(!base64||!mimeType)return null;
        var key=keyOf(base64,mimeType,cols,rows);
        if(CACHE.has(key))return CACHE.get(key);
        if(CACHE.size>64)CACHE.clear();
        CACHE.set(key,null);
        if(mimeType.indexOf("png")>=0){
          var lines=render(base64,cols,rows);
          CACHE.set(key,lines);
          if(!lines)debug("png decode failed for "+mimeType+" "+base64.length+" bytes");
          return lines;
        }
        Promise.resolve()
          .then(function(){return new Bun.Image(Buffer.from(base64,"base64")).png().bytes();})
          .then(function(bytes){
            var lines2=render(Buffer.from(bytes).toString("base64"),cols,rows);
            CACHE.set(key,lines2);
            if(!lines2)debug("converted decode failed for "+mimeType);
            if(owner&&owner.requestRender)owner.requestRender();
          })
          .catch(function(err){debug("convert failed for "+mimeType+": "+err);});
        return null;
      }catch(e){debug(String(e));return null;}
    }
  };
})();
`;

/** Composer band: replace the icon fallback with the half-block thumbnail. */
const BAND_ANCHOR = 'let n=b.symbol(s==="video"?"chip.video":"chip.image")';
const BAND_PATCH =
  "{var _t=globalThis.__ompPasteImages&&globalThis.__ompPasteImages.thumb(e.data,e.mimeType,Ib,Apt,this);if(_t)return _t}" +
  BAND_ANCHOR;

/** Transcript: give user/developer messages the same Image children tool results get. */
const TRANSCRIPT_ANCHOR = 'this.ctx.chatContainer.addChild(r)}break}case"assistant"';
const TRANSCRIPT_PATCH =
  "this.ctx.chatContainer.addChild(r)}" +
  MARK +
  "try{" +
  "var _c=Array.isArray(e.content)?e.content:[];" +
  "for(var _i=0;_i<_c.length;_i++){" +
  "var _b=_c[_i];" +
  'if(_b&&_b.type==="image"&&_b.data&&_b.mimeType&&Ct.imageProtocol){' +
  "this.ctx.chatContainer.addChild(new Ee(1));" +
  'this.ctx.chatContainer.addChild(new kh(_b.data,_b.mimeType,{fallbackColor:function(_x){return b.fg("toolOutput",_x);}},Object.assign({},WH(),{imageKey:"ompimg:"+(e.timestamp||0)+":"+_i})));' +
  "}" +
  "}" +
  "}catch(_e){if(process.env.OMP_PASTE_DEBUG)console.error(\"omp-paste-images: \"+_e);}" +
  'break}case"assistant"';

/**
 * Card geometry. Stock is a fixed 12x4 cells: with half-blocks that is a 12x8
 * pixel thumbnail for every image, which reads as a colour blob. Instead the band
 * sizes one card per frame from the first attached image: fill the band width,
 * height follows the image aspect, both capped. `Ib`/`Apt`/`tlo` are module-scope
 * vars the class already reads, so `render()` just rewrites them before building
 * the frame — every downstream use (`#t` borders, `#e` caption, `#n` thumbnail,
 * `#r` centering, `#i` paste text) picks the new size up for free.
 *
 * Simplification: one geometry per band, taken from the first image chip, so a
 * band mixing a text paste and an image sizes both the same way.
 */
const CARD_SIZE_ANCHOR =
  'render(e){let t=this.editor.composerChips();if(t.length===0)return[];let s=["","","","","",""],n=" ".repeat(slo),o=0;for(let r of t){if(o+tlo>e)break;let i=this.#e(r);for(let a=0;a<s.length;a++)s[a]+=(o>0?n:"")+i[a];o+=(o>0?slo:0)+tlo}return s}';
const CARD_SIZE_PATCH =
  // max interior cols / rows; a 2:1 screenshot lands at 40x10 cells = 40x20 samples
  '#g(e,t){var MW=60,MH=10;for(var c of t){if(!c||c.kind==="paste")continue;var d=this.#s(c.image);if(!d)continue;' +
  'var a=d.width/Math.max(1,d.height),avail=Math.max(12,Math.min(MW,e-slo-2));' +
  'var cols=Math.round(avail),rows=Math.round(cols/(2*a));' +
  'if(rows>MH){rows=MH;cols=Math.round(rows*2*a)}' +
  "rows=Math.max(3,Math.min(MH,rows));cols=Math.max(12,Math.min(MW,cols));return{cols:cols,rows:rows}}" +
  'return{cols:Ib,rows:Apt}}' +
  'render(e){let t=this.editor.composerChips();if(t.length===0)return[];var g=this.#g(e,t);Ib=g.cols;Apt=g.rows;tlo=Ib+2;' +
  'let s=Array(Apt+2).fill(""),n=" ".repeat(slo),o=0;for(let r of t){if(o+tlo>e)break;let i=this.#e(r);' +
  'for(let a=0;a<s.length;a++)s[a]+=(o>0?n:"")+i[a];o+=(o>0?slo:0)+tlo}return s}';

const CARD_ICON_ANCHOR = 'return[" ".repeat(Ib),r," ".repeat(Ib)," ".repeat(Ib)]';
const CARD_ICON_PATCH =
  'var _rows=Array(Apt).fill(" ".repeat(Ib));_rows[Math.max(0,Math.floor(Apt/2)-1)]=r;return _rows';

/** Every edit, with the anchor that must appear exactly once in the pristine bundle. */
const EDITS = [
  { name: "band", anchor: BAND_ANCHOR, replacement: BAND_PATCH },
  { name: "transcript", anchor: TRANSCRIPT_ANCHOR, replacement: TRANSCRIPT_PATCH },
  { name: "card-size", anchor: CARD_SIZE_ANCHOR, replacement: CARD_SIZE_PATCH },
  { name: "card-icon", anchor: CARD_ICON_ANCHOR, replacement: CARD_ICON_PATCH },
];

function countOccurrences(haystack, needle) {
  let n = 0;
  for (let i = haystack.indexOf(needle); i >= 0; i = haystack.indexOf(needle, i + 1)) n++;
  return n;
}

function injectHelper(source) {
  const at = source.indexOf("// @bun");
  if (at < 0) throw new Error("bundle head not recognised (no '// @bun')");
  const nl = source.indexOf("\n", at);
  return source.slice(0, nl + 1) + HELPER + source.slice(nl + 1);
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

function status(cliPath) {
  const source = fs.readFileSync(cliPath, "latin1");
  const applied = source.includes(MARK);
  const backup = `${cliPath}${BACKUP_SUFFIX}`;
  console.log(`cli        ${cliPath}`);
  console.log(`patched    ${applied ? "yes" : "no"}`);
  console.log(`backup     ${fs.existsSync(backup) ? backup : "none"}`);
  for (const { name, anchor } of EDITS) {
    console.log(`anchor ${name.padEnd(11)}${countOccurrences(source, anchor)} match(es)`);
  }
  return 0;
}

function apply(cliPath) {
  let source = fs.readFileSync(cliPath, "latin1");
  if (source.includes(MARK)) {
    console.log(`[--] already patched: ${cliPath}`);
    return 0;
  }
  for (const { name, anchor } of EDITS) {
    const n = countOccurrences(source, anchor);
    if (n !== 1) {
      console.error(
        `[!!] anchor '${name}' matched ${n} time(s) — this omp build is not the one the patch targets.\n` +
          "     Nothing was written. Reinstall omp for a matching build, or update tools/patch-paste-images.mjs.",
      );
      return 1;
    }
  }
  const backup = `${cliPath}${BACKUP_SUFFIX}`;
  if (fs.existsSync(backup)) console.log(`[--] backup already present: ${backup}`);
  else {
    fs.copyFileSync(cliPath, backup);
    console.log(`[ok] backup -> ${backup}`);
  }

  source = injectHelper(source);
  for (const { anchor, replacement } of EDITS) source = source.replace(anchor, () => replacement);
  fs.writeFileSync(cliPath, source, "latin1");

  const check = selfTest(cliPath);
  if (!check.ok) {
    fs.copyFileSync(backup, cliPath);
    console.error(`[!!] patched bundle failed to load (${check.detail}) — restored the backup`);
    return 1;
  }
  console.log(`[ok] patched ${cliPath} (${check.detail})`);
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
  console.log(`[ok] restored ${cliPath} from ${backup}`);
  return 0;
}

// ----------------------------------------------------------------------- main

const argv = process.argv.slice(2);
const command = argv.find(a => !a.startsWith("-")) ?? "status";
const cliFlag = argv.indexOf("--cli");
const cliPath = resolveCli(cliFlag >= 0 ? argv[cliFlag + 1] : process.env.OMP_CLI_JS);

let code;
if (command === "status") code = status(cliPath);
else if (command === "apply") code = apply(cliPath);
else if (command === "revert") code = revert(cliPath);
else {
  console.error(`unknown command '${command}' — use: status | apply | revert [--cli <path to cli.js>]`);
  code = 2;
}
process.exit(code);
