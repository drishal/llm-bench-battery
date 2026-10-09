// pagoda_grade.mjs <file.html> — headless grader for the voxel-pagoda creative task.
//
// WHY THIS EXISTS: the failure mode this task produces is NOT a syntax error.
// Ornith-1.5 (both APEX and official Q6_K) emitted files that pass `node --check`
// and then die at runtime on an undefined identifier — e.g. `ReferenceError: z is
// not defined` from a doorway loop referencing a sibling loop's variable. A grader
// that only lints will score those as PASS. So we EXECUTE the scene code against
// real three.js with a stubbed WebGLRenderer + DOM, which is the same trick omp used
// and the check pi ran that hermes never did.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const THREE_PATH = pathToFileURL(path.join(HERE, 'fixtures', 'three.module.js')).href;
const file = process.argv[2];
const out = (o) => { console.log(JSON.stringify(o)); process.exit(0); };

if (!file || !fs.existsSync(file)) out({ verdict: 'FAIL', stage: 'missing', error: `no such file: ${file}` });
const html = fs.readFileSync(file, 'utf8');
const bytes = Buffer.byteLength(html);

// ---- stage 1: is there a module at all, and does it parse?
const m = html.match(/<script[^>]*type=["']module["'][^>]*>([\s\S]*?)<\/script>/i);
const inlineUmd = /<script(?![^>]*type=["']module)[^>]*>[\s\S]{200000,}<\/script>/i.test(html);
if (!m) out({ verdict: 'FAIL', stage: 'no-module', promptVersion: 2, bytes, inlineUmd,
               error: inlineUmd ? 'no ES module; a huge UMD bundle was inlined instead' : 'no <script type="module"> found' });
let src = m[1];

// ---- stage 2: rewrite imports to the vendored copy; stub the addons + renderer
const stubDir = fs.mkdtempSync(path.join(process.env.TMPDIR || '/tmp', 'pagoda-'));
// OrbitControls.target is a REAL THREE.Vector3, not a bag of two methods. The old stub
// gave it only {set,copy}, so any scene touching controls.target.clone()/.lerp()/.x --
// all legitimate, documented API -- died with "not a function" and was scored FAIL.
// That penalised CORRECT code: verified 2026-08-29 against a hand-checked good pagoda.
// Import the vendored Vector3 so the stub matches the real class surface.
fs.writeFileSync(path.join(stubDir, 'addons.mjs'),
  `import { Vector3 } from ${JSON.stringify(THREE_PATH)};
   export class OrbitControls {
     constructor(c, d){ this.object=c; this.domElement=d; this.target=new Vector3();
       this.enabled=true; this.enableDamping=false; this.dampingFactor=0.05;
       this.minDistance=0; this.maxDistance=Infinity; this.minPolarAngle=0;
       this.maxPolarAngle=Math.PI; this.autoRotate=false; this.autoRotateSpeed=2; }
     update(){ return false; } dispose(){} addEventListener(){} removeEventListener(){}
     saveState(){} reset(){} getDistance(){ return 10; } listenToKeyEvents(){} }
   export default {};\n`);
const ADDONS = pathToFileURL(path.join(stubDir, 'addons.mjs')).href;

src = src.replace(/(["'])three\1/g, `"${THREE_PATH}"`)
         .replace(/(["'])three\/addons\/[^"']*\1/g, `"${ADDONS}"`)
         .replace(/(["'])https?:\/\/[^"']*OrbitControls[^"']*\1/g, `"${ADDONS}"`)
         .replace(/(["'])https?:\/\/[^"']*three\.module\.js\1/g, `"${THREE_PATH}"`);
const hadRenderer = /new\s+THREE\.WebGLRenderer\s*\(/.test(src) || /new\s+WebGLRenderer\s*\(/.test(src);
// NB: replace only the constructor NAME, never try to regex-match its argument list --
// `new THREE.WebGLRenderer({ canvas: document.getElementById("canvas") })` contains a
// nested ')' and a non-greedy paren match truncates it into a syntax error.
src = src.replace(/new\s+(?:THREE\.)?WebGLRenderer\b/g, 'globalThis.__stubRenderer');

// ---- stage 3: minimal DOM
const grad = () => ({ addColorStop(){} });
const ctx2d = (canvas) => new Proxy({ canvas, fillStyle:'', strokeStyle:'', lineWidth:1,
    globalAlpha:1, font:'', textAlign:'', textBaseline:'', globalCompositeOperation:'' }, {
  get(t,p){ if (p in t) return t[p];
    if (p === 'createLinearGradient' || p === 'createRadialGradient') return grad;
    if (p === 'getImageData') return (x,y,w=1,h=1) => ({ data:new Uint8ClampedArray(w*h*4), width:w, height:h });
    if (p === 'measureText') return () => ({ width: 0 });
    return function(){}; },
  set(t,p,v){ t[p]=v; return true; } });
const el = () => new Proxy({ style:{}, classList:{add(){},remove(){}}, children:[], dataset:{} }, {
  get(t,p){ if (p in t) return t[p];
    // A real browser hands back a working 2D context; returning null here made any
    // scene that builds a procedural canvas texture (petals, sprites, gradients --
    // very common) false-FAIL on `clearRect of null`. Hand back a no-op context.
    if (p === 'getContext') return () => ctx2d(t);
    return function(){ return el(); }; },
  set(t,p,v){ t[p]=v; return true; } });
try { globalThis.window = globalThis; } catch {}
globalThis.document = { getElementById: () => el(), querySelector: () => el(), querySelectorAll: () => [],
  createElement: () => el(), createElementNS: () => el(), body: el(), documentElement: el(),
  addEventListener(){}, removeEventListener(){} };
try { Object.defineProperty(globalThis,'navigator',{value:{userAgent:'node'},configurable:true}); } catch {}
globalThis.requestAnimationFrame = () => 0;
globalThis.cancelAnimationFrame = () => {};
globalThis.performance = globalThis.performance || { now: () => 0 };
globalThis.addEventListener = () => {};
globalThis.innerWidth = 1920; globalThis.innerHeight = 1080; globalThis.devicePixelRatio = 1;
globalThis.__stubRenderer = (_opts) => new Proxy({ domElement: el(), shadowMap:{}, capabilities:{ getMaxAnisotropy:()=>1 }, info:{} },
  { get(t,p){ if (p in t) return t[p]; return function(){}; }, set(t,p,v){ t[p]=v; return true; } });

// ---- stage 4: instrument three, then execute
const THREE = await import(THREE_PATH);
let addCalls = 0;
const origAdd = THREE.Object3D.prototype.add;
// Track InstancedMesh so we can verify the instance buffers were actually FILLED.
// A scene can execute cleanly, add 178 objects and still render almost nothing:
// verified 2026-09-04 on a 10/10 pagoda whose helper incremented `mesh.count` but
// indexed setMatrixAt() with a counter it never advanced -- every voxel overwrote
// slot 0, so 80 cubes of 34,514 were visible. Linting and execution BOTH pass that.
const instanced = [];
const added = [];
THREE.Object3D.prototype.add = function (...a) {
  addCalls += a.length;
  for (const o of a) { if (o && o.isInstancedMesh) instanced.push(o); if (o) added.push(o); }
  return origAdd.apply(this, a);
};
const probe = path.join(stubDir, 'scene.mjs');
fs.writeFileSync(probe, src);
try {
  await import(pathToFileURL(probe).href);
} catch (e) {
  out({ verdict: 'FAIL', stage: 'runtime', promptVersion: 2, bytes, hadRenderer,
        error: String(e && e.message || e),
        where: (String(e && e.stack || '').split('\n')[1] || '').trim().replace(stubDir, '<probe>') });
}
// ---- stage 4b: did the instance buffers actually get FILLED with distinct transforms?
// three.js pre-fills instanceMatrix with the IDENTITY matrix, so an unwritten slot is
// not invisible -- it is a unit cube stacked at the origin. Testing for all-zero misses
// that entirely. Distinct-matrix count catches both failure shapes: unwritten identity
// slots AND a helper that indexes every write to the same slot.
let instDrawn = 0, instLive = 0, instOverflow = 0;
for (const m of instanced) {
  const cap = (m.instanceMatrix && m.instanceMatrix.count) || 0;
  const drawn = Math.max(0, m.count | 0);
  instDrawn += drawn;
  if (drawn > cap) instOverflow++;          // draws past the buffer: undefined reads
  const arr = m.instanceMatrix && m.instanceMatrix.array;
  if (!arr) continue;
  const seen = new Set();
  for (let i = 0; i < Math.min(drawn, cap); i++) {
    const o = i * 16;
    // position columns (12,13,14) + scale diagonal are enough to identify a placement
    seen.add(arr[o+12]+","+arr[o+13]+","+arr[o+14]+","+arr[o]+","+arr[o+5]+","+arr[o+10]);
  }
  instLive += seen.size;                    // distinct placements this mesh renders
}
const instRatio = instDrawn > 0 ? instLive / instDrawn : 1;

// ---- stage 4c: harvest what ACTUALLY renders (post-execution scene graph).
// ⚠ A voxel scene colours via InstancedMesh.setColorAt() or vertexColors, NOT
// material.color -- reading only material.color reported Glimmer's 401-mesh scene
// as "2 colours". Read all three sources.
const colours = new Set(), geoms = new Set();
let meshes = 0;
const quant = (r,g,b) => (Math.round(r*255)<<16 | Math.round(g*255)<<8 | Math.round(b*255));
for (const root of added) {
  try {
    root.traverse((o) => {
      if (!o) return;
      if (o.isMesh || o.isInstancedMesh || o.isPoints || o.isLine) meshes++;
      if (o.geometry && o.geometry.type) geoms.add(o.geometry.type);
      const mats = Array.isArray(o.material) ? o.material : (o.material ? [o.material] : []);
      for (const mm of mats) if (mm && mm.color && typeof mm.color.getHex === 'function') colours.add(mm.color.getHex());
      const ic = o.instanceColor && o.instanceColor.array;      // setColorAt()
      if (ic) for (let i = 0; i + 2 < ic.length; i += 3) colours.add(quant(ic[i], ic[i+1], ic[i+2]));
      const ca = o.geometry && o.geometry.attributes && o.geometry.attributes.color;
      if (ca && ca.array) { const a = ca.array, st = ca.itemSize || 3;
        for (let i = 0; i + 2 < a.length; i += st) colours.add(quant(a[i], a[i+1], a[i+2])); }
    });
  } catch {}
}

const has = (re) => re.test(html);
const features = { pagoda: has(/pagoda/i), blossom: has(/blossom|petal|sakura|cherry/i),
                   water: has(/pond|water|koi/i), lantern: has(/lantern/i),
                   bridge: has(/bridge/i), torii: has(/torii/i),
                   animation: has(/requestAnimationFrame|setAnimationLoop/i) };
const nFeat = Object.values(features).filter(Boolean).length;

// ---- PROMPT v2 GATES: one per stated requirement, binary and machine-checkable.
// Quality stays the user's eyeball -- VoxelCodeBench (arXiv 2604.02580) published that
// automated metrics "cannot assess whether the generated 3D scene actually matches the
// intended specification". We grade COMPLIANCE, not beauty.
const srcHas = (re) => re.test(src) || re.test(html);
// Allowed: the three.js CDN in the supplied boilerplate + the importmap polyfill.
const extUrls = [...html.matchAll(/https?:\/\/[^"'\s)]+/g)].map(x => x[0]).filter(u =>
  !/(cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)\/(npm\/)?(three@|ajax\/libs\/three|es-module-shims)/.test(u) &&
  !/^https?:\/\/(www\.)?(w3\.org|schema\.org)/.test(u));
const gates = {
  fileWritten:   bytes > 0,
  webgl:         hadRenderer,
  fillsWindow:   srcHas(/innerWidth/) && srcHas(/innerHeight/),
  resizes:       srcHas(/addEventListener\s*\(\s*["']resize["']/) || srcHas(/onresize/),
  orbit:         srcHas(/OrbitControls/) && !srcHas(/enableZoom\s*[:=]\s*false/) && !srcHas(/enableRotate\s*[:=]\s*false/),
  animated:      srcHas(/requestAnimationFrame|setAnimationLoop/),
  // "8 distinct element types" -- measured as the named things actually present.
  // NOT a mesh count: one InstancedMesh legitimately holds a whole voxel scene.
  elementTypes:  nFeat >= 5,
  colours:       colours.size >= 6,
  // scene must be substantial, by EITHER technique (plain meshes or instancing)
  richness:      addCalls >= 15 || instDrawn >= 200 || meshes >= 8,
  // instance buffers actually filled -- catches the fake 10/10 (instRatio 0.005)
  instancesRendered: !(instDrawn >= 200 && instRatio < 0.5),
  noExternal:    extUrls.length === 0,
  sceneNonEmpty: addCalls > 0,
};
const gatesFailed = Object.entries(gates).filter(([, v]) => !v).map(([k]) => k);

// ---- score 0-10. Binary PASS/FAIL could not separate "built a rich scene" from
// "emitted one cube", which is exactly the discrimination the battery was missing.
//   4  executes at all and puts something in the scene (the old PASS bar)
//  +3  richness, by how many objects actually reached the scene graph
//  +3  breadth, by how many of the 7 asked-for elements are present
let score = 0;
if (addCalls > 0) {
  score = 4;
  score += addCalls >= 30 ? 3 : addCalls >= 15 ? 2 : addCalls >= 5 ? 1 : 0;
  score += nFeat >= 6 ? 3 : nFeat >= 4 ? 2 : nFeat >= 2 ? 1 : 0;
  // A scene whose instance buffers are mostly empty does not render, however
  // rich its source looks. Scale the whole score by what actually made it in.
  // Threshold is deliberately loose: legitimate scenes overlap voxels and land
  // around 0.89, while the real failure measured 0.005 -- three orders of magnitude
  // apart, so only genuine breakage trips this.
  if (instDrawn >= 200 && instRatio < 0.5) {
    score = instRatio < 0.25 ? Math.min(score, 3) : Math.min(score, 5);
  }
}
out({ verdict: gatesFailed.length === 0 ? 'PASS' : 'FAIL',
      stage: gatesFailed.length === 0 ? 'ok' : 'gate:' + gatesFailed[0],
      promptVersion: 2,
      gatesFailed,
      gates,
      // v1 heuristic score kept alongside so the old series stays readable.
      // It is NOT the verdict any more -- it scored a broken scene 10/10.
      score, maxScore: 10,
      bytes, hadRenderer, meshes, colours: colours.size, geomTypes: geoms.size,
      sceneAdds: addCalls, featureCount: nFeat,
      instDrawn, instLive, instRatio: Number(instRatio.toFixed(3)), instOverflow,
      extUrls: extUrls.slice(0, 5),
      features });
