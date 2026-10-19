// PICO Neo 3 controller: joystick plane, pivot, and the vrserver joystick transform.
// Geometry comes from model.js, which temp/joyaxis/export_model.py generates from the
// original OBJ files. Nothing here guesses the pad orientation: it is measured.

import * as THREE from "./three.module.js";
import { FRAME, MESHES } from "./model.js";

const DEG = Math.PI / 180;
const vec = (a) => new THREE.Vector3(a[0], a[1], a[2]);

// Measured pad frame. N = pad normal (= stick axis), UP = away from the grip,
// RIGHT = N x UP as seen by the user with the pad facing them.
const N = vec(FRAME.n).normalize();
const UP = vec(FRAME.up).normalize();
const RIGHT = vec(FRAME.right).normalize();
const EH = RIGHT.clone().negate(); // horizontal axis inside the pad plane
const AXIS_AT_PLANE = vec(FRAME.axisAtPlane); // centre of the hole the body cuts
const STICK_TIP = vec(FRAME.axisEnd).addScaledVector(N, FRAME.capT); // cap centre, on the stick axis
const S = new THREE.Matrix4().makeBasis(vec(FRAME.S[0]), vec(FRAME.S[1]), vec(FRAME.S[2]));
const VENDOR_PIVOT = new THREE.Vector3(0, 0, 20); // vendor center, 25 mm off the stick axis

const state = {
  inX: 0,
  inY: 0,
  amp: 8,
  depth: 4,
  press: false,
  pressMm: 2.5,
  demo: false,
  plane: true,
  axes: true,
  pivot: true,
  clip: false,
  ring: false,
  vendor: false,
  bounds: false,
  grid: false,
  view: "pad",
  mirror: false,
};

// ---------------------------------------------------------------- scene ----
const view = document.getElementById("view");
const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.outputColorSpace = THREE.SRGBColorSpace;
renderer.toneMapping = THREE.ACESFilmicToneMapping;
renderer.toneMappingExposure = 1.05;
renderer.localClippingEnabled = true;
view.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(35, 1, 1, 4000);

scene.add(new THREE.HemisphereLight(0xdfe9f5, 0x1a2028, 2.1));
const key = new THREE.DirectionalLight(0xffffff, 1.55);
key.position.set(-60, -120, 110);
const fill = new THREE.DirectionalLight(0x9fc4ff, 0.7);
fill.position.set(90, 40, -70);
const rim = new THREE.DirectionalLight(0xffd9b0, 0.45);
rim.position.set(30, 110, 60);
scene.add(key, fill, rim);

let clipPlane = new THREE.Plane(RIGHT.clone().negate(), RIGHT.dot(AXIS_AT_PLANE));
// cuts away the tracking ring, which hangs in front of the pad and hides the stick
let ringPlane = new THREE.Plane(N.clone().negate(), N.dot(AXIS_AT_PLANE) + 20);
// The mirror is an x flip of the model space: preset directions, target points and
// the world-space clip planes all have to go through it.  A plain negation is wrong
// (the pad normal has a y component), and it silently cuts the wrong half.
const handed = (v) => (state.mirror ? new THREE.Vector3(-v.x, v.y, v.z) : v.clone());
function rebuildClipPlanes() {
  clipPlane = new THREE.Plane(handed(RIGHT).negate(), RIGHT.dot(AXIS_AT_PLANE));
  ringPlane = new THREE.Plane(handed(N).negate(), N.dot(AXIS_AT_PLANE) + 20);
}

const MATS = {
  body: new THREE.MeshStandardMaterial({ color: 0xc3ccd7, roughness: 0.62, metalness: 0.06, side: THREE.DoubleSide }),
  grip: new THREE.MeshStandardMaterial({ color: 0x9aa6b3, roughness: 0.7, metalness: 0.05, side: THREE.DoubleSide }),
  button: new THREE.MeshStandardMaterial({ color: 0x6f7c8b, roughness: 0.45, metalness: 0.1 }),
  stick: new THREE.MeshStandardMaterial({ color: 0x4a5b6e, roughness: 0.42, metalness: 0.12, side: THREE.DoubleSide }),
};

function geometryOf(part) {
  const m = MESHES[part];
  const g = new THREE.BufferGeometry();
  g.setAttribute("position", new THREE.Float32BufferAttribute(m.pos, 3));
  g.setIndex(m.idx);
  g.computeVertexNormals();
  return g;
}

const group = new THREE.Group();
scene.add(group);
for (const [part, mat] of [["body", MATS.body], ["grip", MATS.grip], ["x", MATS.button],
  ["y", MATS.button], ["app", MATS.button], ["home", MATS.button]]) {
  const m = new THREE.Mesh(geometryOf(part), mat);
  m.name = part;
  group.add(m);
}
const stick = new THREE.Mesh(geometryOf("stick"), MATS.stick);
stick.name = "stick";
stick.matrixAutoUpdate = false;
group.add(stick);

const ghost = new THREE.Mesh(
  geometryOf("stick"),
  new THREE.MeshStandardMaterial({ color: 0xff6b6b, wireframe: true, transparent: true, opacity: 0.55 })
);
ghost.matrixAutoUpdate = false;
ghost.visible = false;
group.add(ghost);

// -------------------------------------------------------------- helpers ----
const helperMat = (c, o, w = 1.4) =>
  new THREE.LineBasicMaterial({ color: c, transparent: true, opacity: o, linewidth: w });

const planeGroup = new THREE.Group();
{
  const disc = new THREE.Mesh(
    new THREE.CircleGeometry(27, 96),
    new THREE.MeshBasicMaterial({ color: 0x59b0ff, transparent: true, opacity: 0.09, side: THREE.DoubleSide, depthWrite: false })
  );
  const ring = new THREE.LineLoop(
    new THREE.BufferGeometry().setFromPoints(
      Array.from({ length: 96 }, (_, i) => {
        const a = (i / 96) * Math.PI * 2;
        return new THREE.Vector3(Math.cos(a) * 27, Math.sin(a) * 27, 0);
      })
    ),
    helperMat(0x59b0ff, 0.5)
  );
  planeGroup.add(disc, ring);
  // the plane's own up / right, drawn on the disc so the frame is readable
  const dirUp = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3(0, 24, 0)]),
    helperMat(0x4cc38a, 0.9)
  );
  const dirRight = new THREE.Line(
    new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3(24, 0, 0)]),
    helperMat(0xe3b341, 0.9)
  );
  planeGroup.add(dirUp, dirRight);
  // disc local x = RIGHT, y = UP, z = N
  planeGroup.quaternion.setFromRotationMatrix(new THREE.Matrix4().makeBasis(RIGHT, UP, N));
  planeGroup.position.copy(AXIS_AT_PLANE).addScaledVector(N, 0.15);
  group.add(planeGroup);
}

const axisGroup = new THREE.Group();
group.add(axisGroup);
const pivotBall = new THREE.Mesh(
  new THREE.SphereGeometry(1.05, 20, 14),
  new THREE.MeshBasicMaterial({ color: 0xff4d6d })
);
const axisLine = new THREE.Line(
  new THREE.BufferGeometry().setFromPoints([new THREE.Vector3(), new THREE.Vector3()]),
  new THREE.LineDashedMaterial({ color: 0x8b97a6, dashSize: 2.2, gapSize: 1.6, transparent: true, opacity: 0.9 })
);
const axisArrows = [];
group.add(pivotBall, axisLine);
for (let i = 0; i < 2; i++) {
  const a = new THREE.ArrowHelper(new THREE.Vector3(0, 1, 0), new THREE.Vector3(), 15, 0xffffff, 3.2, 1.9);
  const b = new THREE.ArrowHelper(new THREE.Vector3(0, -1, 0), new THREE.Vector3(), 9, 0xffffff, 0, 0);
  a.line.material.transparent = b.line.material.transparent = true;
  a.line.material.opacity = 0.95;
  b.line.material.opacity = 0.3;
  a.cone.material.transparent = true;
  axisGroup.add(a, b);
  axisArrows.push([a, b]);
}

// ------------------------------------------------------------- transform ---
// vrserver: A(v) = c + R*press + Q*(v - c), Q = R * Rz(thx) * Rx(thy) * R^T
function joystickMatrix(pivot, thx, thy, pressMm, conjugated) {
  const S_ = conjugated ? S : new THREE.Matrix4();
  const Rz = new THREE.Matrix4().makeRotationZ(thx * DEG);
  const Rx = new THREE.Matrix4().makeRotationX(thy * DEG);
  const Q = new THREE.Matrix4()
    .multiplyMatrices(S_, new THREE.Matrix4().multiplyMatrices(Rz, Rx))
    .multiply(S_.clone().transpose());
  const press = new THREE.Vector3(0, -pressMm, 0).applyMatrix4(S_);
  return new THREE.Matrix4()
    .makeTranslation(pivot.x + press.x, pivot.y + press.y, pivot.z + press.z)
    .multiply(Q)
    .multiply(new THREE.Matrix4().makeTranslation(-pivot.x, -pivot.y, -pivot.z));
}

function currentPivot() {
  return AXIS_AT_PLANE.clone().addScaledVector(N, -state.depth);
}

// largest in-plane radius of the transformed stick where it crosses the pad plane
function radiusAtPlane(matrix) {
  const pos = MESHES.stick.pos;
  const idx = MESHES.stick.idx;
  const p = [new THREE.Vector3(), new THREE.Vector3()];
  let maxR = 0;
  for (let i = 0; i < idx.length; i += 3) {
    for (let k = 0; k < 3; k++) {
      const a = idx[i + k];
      const b = idx[i + ((k + 1) % 3)];
      p[0].set(pos[a * 3], pos[a * 3 + 1], pos[a * 3 + 2]).applyMatrix4(matrix);
      p[1].set(pos[b * 3], pos[b * 3 + 1], pos[b * 3 + 2]).applyMatrix4(matrix);
      const ta = p[0].clone().sub(AXIS_AT_PLANE).dot(N);
      const tb = p[1].clone().sub(AXIS_AT_PLANE).dot(N);
      if (ta * tb > 0) continue;
      const u = ta === tb ? 0 : ta / (ta - tb);
      const q = p[0].clone().lerp(p[1], u).sub(AXIS_AT_PLANE);
      maxR = Math.max(maxR, q.addScaledVector(N, -q.dot(N)).length());
    }
  }
  return maxR;
}

const REST_R = radiusAtPlane(new THREE.Matrix4());

// ---------------------------------------------------------------- camera ---
// Turntable rig, the way Blender / Maya orbit: the vertical axis is locked, so
// the horizon never rolls and the model never ends up slanted.
const CAM_UP = new THREE.Vector3(0, 0, -1); // model -z points up (the grip hangs down)
const CAM_E1 = new THREE.Vector3(1, 0, 0);
const CAM_E2 = new THREE.Vector3(0, -1, 0); // CAM_E1 x CAM_E2 = CAM_UP
const rig = { target: AXIS_AT_PLANE.clone(), azim: 0, polar: Math.PI / 2, roll: 0, dist: 95 };
const POLAR_MIN = 0.03;
const POLAR_MAX = Math.PI - 0.03;

function placeCamera() {
  const sp = Math.sin(rig.polar);
  const cp = Math.cos(rig.polar);
  const dir = new THREE.Vector3()
    .addScaledVector(CAM_E1, sp * Math.cos(rig.azim))
    .addScaledVector(CAM_E2, sp * Math.sin(rig.azim))
    .addScaledVector(CAM_UP, cp)
    .normalize();
  camera.up.copy(CAM_UP).applyAxisAngle(dir, rig.roll); // roll frees the locked horizon
  camera.position.copy(rig.target).addScaledVector(dir, rig.dist);
  camera.lookAt(rig.target);
}

function setMirror(on) {
  state.mirror = on;
  group.scale.x = on ? -1 : 1;
  rebuildClipPlanes();
  goView(state.view); // the presets point with left-hand vectors, so re-place the camera
  apply();
  persist();
}


function setRoll(deg) {
  rig.roll = THREE.MathUtils.degToRad(deg);
  el("roll").value = String(deg.toFixed(1));
  el("oRoll").textContent = deg.toFixed(0) + "°";
  placeCamera();
}

function aim(eyeDir, target, dist) {
  const d = eyeDir.clone().normalize();
  rig.polar = THREE.MathUtils.clamp(Math.acos(THREE.MathUtils.clamp(d.dot(CAM_UP), -1, 1)), POLAR_MIN, POLAR_MAX);
  rig.azim = Math.atan2(d.dot(CAM_E2), d.dot(CAM_E1));
  rig.target.copy(target);
  rig.dist = dist;
  placeCamera();
}

const box = new THREE.Box3();
box.makeEmpty();
for (const m of Object.values(MESHES)) {
  for (let i = 0; i < m.pos.length; i += 3) box.expandByPoint(new THREE.Vector3(m.pos[i], m.pos[i + 1], m.pos[i + 2]));
}

// model origin + the whole controller's axis-aligned bounds
const boundsGroup = new THREE.Group();
group.add(boundsGroup);
{
  const axes = new THREE.AxesHelper(22);
  axes.material.transparent = true;
  axes.material.opacity = 0.95;
  axes.material.depthTest = false;
  const originBall = new THREE.Mesh(
    new THREE.SphereGeometry(1.0, 16, 12),
    new THREE.MeshBasicMaterial({ color: 0xffffff, depthTest: false })
  );
  const boxHelper = new THREE.Box3Helper(box, 0x5ad1a0);
  boxHelper.material.transparent = true;
  boxHelper.material.opacity = 0.75;
  boundsGroup.add(axes, originBall, boxHelper);
  boundsGroup.renderOrder = 10;
  boundsGroup.visible = false;
}

// dotted reference grid on the plane z = 0 (model height 0)
const gridGroup = new THREE.Group();
group.add(gridGroup);
{
  const extent = 70;
  const step = 10;
  const dashed = (a, b, color, opacity) => {
    const g = new THREE.BufferGeometry().setFromPoints([a, b]);
    const l = new THREE.Line(
      g,
      new THREE.LineDashedMaterial({ color, dashSize: 1.6, gapSize: 1.9, transparent: true, opacity, depthWrite: false })
    );
    l.computeLineDistances();
    return l;
  };
  for (let a = -extent; a <= extent; a += step) {
    const major = a === 0;
    const color = major ? 0x7fa8e0 : 0x39506e;
    const opacity = major ? 0.85 : 0.5;
    gridGroup.add(
      dashed(new THREE.Vector3(-extent, a, 0), new THREE.Vector3(extent, a, 0), color, opacity),
      dashed(new THREE.Vector3(a, -extent, 0), new THREE.Vector3(a, extent, 0), color, opacity)
    );
  }
  gridGroup.visible = false;
}

function goView(name) {
  state.view = name;
  setRoll(0);
  if (name === "pad") {
    // straight down the pad normal the tracking ring hides the stick, so look in
    // from ~50 deg off, which clears the ring
    aim(handed(N).multiplyScalar(0.62).addScaledVector(handed(EH), 0.68).addScaledVector(CAM_UP, 0.40),
      handed(AXIS_AT_PLANE), 96);
  } else if (name === "head") {
    aim(handed(N), handed(AXIS_AT_PLANE), 96);
  } else if (name === "section") {
    setClip(true);
    aim(handed(RIGHT), handed(AXIS_AT_PLANE).addScaledVector(handed(N), -1), 62);
  } else if (name === "iso") {
    aim(handed(N).multiplyScalar(0.82).addScaledVector(handed(RIGHT), 0.5).addScaledVector(CAM_UP, 0.28),
      handed(AXIS_AT_PLANE), 96);
  } else if (name === "full") {
    const c = handed(box.getCenter(new THREE.Vector3()));
    const radius = box.getSize(new THREE.Vector3()).length() / 2;
    const fit = (radius / Math.tan((camera.fov * DEG) / 2)) * 1.12;
    aim(handed(N).multiplyScalar(0.8).addScaledVector(handed(RIGHT), 0.5).addScaledVector(CAM_UP, 0.25), c, fit);
  }
  persist();
}

let clipSig = null;
function applyClipping() {
  const planes = [];
  if (state.clip) planes.push(clipPlane);
  if (state.ring) planes.push(ringPlane);
  const sig = planes.map((p) => p.normal.toArray().join(",") + p.constant).join("|");
  if (sig === clipSig) return;
  clipSig = sig;
  for (const m of Object.values(MATS)) {
    m.clippingPlanes = planes;
    m.needsUpdate = true;
  }
  stick.material.clippingPlanes = planes;
  stick.material.needsUpdate = true;
}

function setClip(on) {
  state.clip = on;
  el("sClip").checked = on;
  applyClipping();
}

// pointer handling: left / middle drag = turntable orbit, right or shift = pan, wheel = dolly
let drag = null;
renderer.domElement.addEventListener("contextmenu", (e) => e.preventDefault());
renderer.domElement.addEventListener("pointerdown", (e) => {
  drag = { x: e.clientX, y: e.clientY, pan: e.button !== 0 || e.shiftKey || e.altKey };
  renderer.domElement.setPointerCapture(e.pointerId);
});
renderer.domElement.addEventListener("pointerup", () => (drag = null));
renderer.domElement.addEventListener("pointermove", (e) => {
  if (!drag) return;
  const dx = e.clientX - drag.x;
  const dy = e.clientY - drag.y;
  drag.x = e.clientX;
  drag.y = e.clientY;
  if (!drag.pan) {
    rig.azim -= dx * 0.0062;
    rig.polar = THREE.MathUtils.clamp(rig.polar - dy * 0.0062, POLAR_MIN, POLAR_MAX);
  } else {
    const perPixel = (2 * rig.dist * Math.tan((camera.fov * DEG) / 2)) / renderer.domElement.clientHeight;
    const right = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 0);
    const up = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 1);
    rig.target.addScaledVector(right, -dx * perPixel).addScaledVector(up, dy * perPixel);
  }
  placeCamera();
});
renderer.domElement.addEventListener("wheel", (e) => {
  e.preventDefault();
  rig.dist *= Math.exp(e.deltaY * 0.0011);
  rig.dist = THREE.MathUtils.clamp(rig.dist, 12, 900);
  placeCamera();
}, { passive: false });
renderer.domElement.addEventListener("dblclick", () => goView(state.view));

const keys = new Set();
addEventListener("keydown", (e) => keys.add(e.key.toLowerCase()));
addEventListener("keyup", (e) => keys.delete(e.key.toLowerCase()));

// ------------------------------------------------------------------- UI ----
const el = (id) => document.getElementById(id);
const readout = el("readout");
const params = new URLSearchParams(location.search);
const READ_ONLY = params.has("view"); // screenshot mode: take no state from or to the browser

function persist() {
  if (READ_ONLY || state.demo) return;
  localStorage.setItem("joyaxis-v1", JSON.stringify(state));
}

function restore() {
  try {
    const s = JSON.parse(localStorage.getItem("joyaxis-v1"));
    if (s) Object.assign(state, s);
  } catch { /* ignore a corrupt record */ }
}

function readUI() {
  el("inX").value = state.inX;
  el("inY").value = state.inY;
  el("amp").value = state.amp;
  el("dep").value = state.depth;
  el("press").checked = state.press;
  el("sPlane").checked = state.plane;
  el("sAxes").checked = state.axes;
  el("sPivot").checked = state.pivot;
  el("sClip").checked = state.clip;
  el("sRing").checked = state.ring;
  el("pressMm").value = state.pressMm;
  el("sVendor").checked = state.vendor;
  el("sBounds").checked = state.bounds;
  el("sGrid").checked = state.grid;
  el("sDemo").checked = state.demo;
  el("sMirror").checked = state.mirror;
}

const fmt = (v, n = 2) => (v >= 0 ? "+" : "") + v.toFixed(n);

function apply() {
  const thx = state.amp * state.inX;
  const thy = state.amp * state.inY;
  const pressMm = state.press ? state.pressMm : 0;
  const pivot = currentPivot();

  stick.matrix.copy(joystickMatrix(pivot, thx, thy, pressMm, true));
  stick.matrixWorldNeedsUpdate = true;
  ghost.visible = state.vendor;
  if (state.vendor) {
    ghost.matrix.copy(joystickMatrix(VENDOR_PIVOT, thx, thy, pressMm, false));
    ghost.matrixWorldNeedsUpdate = true;
  }

  planeGroup.visible = state.plane;
  axisGroup.visible = state.axes;
  pivotBall.visible = state.pivot;
  axisLine.visible = state.pivot;
  boundsGroup.visible = state.bounds;
  gridGroup.visible = state.grid;
  applyClipping();

  pivotBall.position.copy(pivot);
  // the two hard-coded vrserver axes, conjugated into the pad plane
  const axX = new THREE.Vector3(0, 0, 1).applyMatrix4(S.clone().setPosition(0, 0, 0));
  const axY = new THREE.Vector3(1, 0, 0).applyMatrix4(S.clone().setPosition(0, 0, 0));
  [[axX, 0xff8f5a], [axY, 0x59b0ff]].forEach(([dir, col], i) => {
    const [a, b] = axisArrows[i];
    a.position.copy(pivot);
    a.setDirection(dir);
    a.setColor(new THREE.Color(col));
    b.position.copy(pivot);
    b.setDirection(dir.clone().negate());
    b.setColor(new THREE.Color(col));
  });

  const linePts = [
    AXIS_AT_PLANE.clone().addScaledVector(N, -Math.max(state.depth + 4, 8)),
    AXIS_AT_PLANE.clone().addScaledVector(N, 12),
  ];
  axisLine.geometry.dispose();
  axisLine.geometry = new THREE.BufferGeometry().setFromPoints(linePts);
  axisLine.computeLineDistances();

  // numbers: cap-top travel and the stick's radius where it crosses the pad plane
  const top = STICK_TIP.clone().applyMatrix4(stick.matrix);
  const d = top.clone().sub(STICK_TIP);
  const maxR = radiusAtPlane(stick.matrix);

  el("oInX").textContent = fmt(state.inX);
  el("oInY").textContent = fmt(state.inY);
  el("oAmp").textContent = state.amp.toFixed(1) + "°";
  el("oDep").textContent = fmt(state.depth, 1) + " mm";
  el("oPress").textContent = state.pressMm.toFixed(1) + " mm";

  readout.innerHTML =
    `θx = ${fmt(thx, 1)}°   θy = ${fmt(thy, 1)}°\n` +
    `帽顶位移  右 ${fmt(d.dot(RIGHT))}  上 ${fmt(d.dot(UP))}  法向 ${fmt(d.dot(N))} mm\n` +
    `平面处半径 ${maxR.toFixed(2)} mm（静止 ${REST_R.toFixed(2)}，${fmt(maxR - REST_R)}）\n` +
    `杆顶露出 ${FRAME.protrusion.toFixed(2)} / 埋入 ${FRAME.buried.toFixed(2)} mm\n` +
    `支点 ${state.depth >= 0 ? "平面下" : "平面上方"} ${Math.abs(state.depth).toFixed(1)} mm（在杆轴上）` +
    (state.mirror ? "  ·  右手（镜像）" : "") +
    (state.bounds
      ? `\n包围盒 x ${box.min.x.toFixed(1)}..${box.max.x.toFixed(1)}` +
        `  y ${box.min.y.toFixed(1)}..${box.max.y.toFixed(1)}` +
        `  z ${box.min.z.toFixed(1)}..${box.max.z.toFixed(1)} mm`
      : "");

  persist();
}

// wiring
el("inX").addEventListener("input", (e) => { state.inX = +e.target.value; apply(); });
el("inY").addEventListener("input", (e) => { state.inY = +e.target.value; apply(); });
el("amp").addEventListener("input", (e) => { state.amp = +e.target.value; apply(); });
el("dep").addEventListener("input", (e) => { state.depth = +e.target.value; apply(); });
el("roll").addEventListener("input", (e) => setRoll(+e.target.value));
el("press").addEventListener("change", (e) => { state.press = e.target.checked; apply(); });
el("pressMm").addEventListener("input", (e) => { state.pressMm = +e.target.value; apply(); });
for (const [id, key] of [["sPlane", "plane"], ["sAxes", "axes"], ["sPivot", "pivot"], ["sVendor", "vendor"], ["sBounds", "bounds"], ["sGrid", "grid"]]) {
  el(id).addEventListener("change", (e) => { state[key] = e.target.checked; apply(); });
}
el("sClip").addEventListener("change", (e) => { setClip(e.target.checked); apply(); });
el("sMirror").addEventListener("change", (e) => setMirror(e.target.checked));
el("sRing").addEventListener("change", (e) => {
  state.ring = e.target.checked;
  applyClipping();
  persist();
});
for (const b of document.querySelectorAll("[data-view]")) b.addEventListener("click", () => goView(b.dataset.view));
for (const b of document.querySelectorAll("[data-push]")) {
  b.addEventListener("click", () => {
    const [x, y] = b.dataset.push.split(",").map(Number);
    state.inX = x;
    state.inY = y;
    state.demo = false;
    readUI();
    apply();
  });
}
el("sDemo").addEventListener("change", (e) => {
  state.demo = e.target.checked;
  persist();
});
for (const b of document.querySelectorAll("[data-depth]")) {
  b.addEventListener("click", () => { state.depth = +b.dataset.depth; el("dep").value = state.depth; apply(); });
}

function resize() {
  const w = view.clientWidth;
  const h = view.clientHeight;
  renderer.setSize(w, h, false);
  renderer.domElement.style.width = w + "px";
  renderer.domElement.style.height = h + "px";
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
}
new ResizeObserver(resize).observe(view);

// -------------------------------------------------------------- main loop --
const clock = new THREE.Clock();
let demoPhase = 0;
function tick() {
  const dt = Math.min(clock.getDelta(), 0.05);
  if (state.demo) {
    demoPhase += dt * (Math.PI / 2.2);
    state.inX = Math.cos(demoPhase) * 0.9;
    state.inY = Math.sin(demoPhase) * 0.9;
    el("inX").value = state.inX;
    el("inY").value = state.inY;
    apply();
  }
  // WASD pans inside the screen plane, the same gesture as the right-button drag.
  // Moving the orbit centre along the view direction (the old behaviour) left it off
  // the model, so orbiting afterwards swung the model out of the frame.
  const speed = rig.dist * 0.9 * dt;
  const rightV = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 0);
  const upV = new THREE.Vector3().setFromMatrixColumn(camera.matrix, 1);
  let moved = false;
  if (keys.has("w")) { rig.target.addScaledVector(upV, speed); moved = true; }
  if (keys.has("s")) { rig.target.addScaledVector(upV, -speed); moved = true; }
  if (keys.has("a")) { rig.target.addScaledVector(rightV, -speed); moved = true; }
  if (keys.has("d")) { rig.target.addScaledVector(rightV, speed); moved = true; }
  if (keys.has("q") || keys.has("e")) {
    setRoll(THREE.MathUtils.radToDeg(rig.roll) + (keys.has("q") ? -dt * 60 : dt * 60));
    moved = true;
  }
  if (moved) placeCamera();
  renderer.render(scene, camera);
  requestAnimationFrame(tick);
}

// screenshot hook for the automated checks
window.shot = (name, w = 1280, h = 860) => {
  renderer.setSize(w, h, false);
  camera.aspect = w / h;
  camera.updateProjectionMatrix();
  renderer.render(scene, camera);
  const data = renderer.domElement.toDataURL("image/png");
  return fetch("/shot?name=" + encodeURIComponent(name), { method: "POST", body: data })
    .then(() => resize())
    .then(() => name);
};
window.state = (patch) => { Object.assign(state, patch); readUI(); apply(); };
window.go = (name, dist) => {
  goView(name);
  if (dist) {
    rig.dist = dist;
    placeCamera();
  }
  return window.dbg();
};
window.frame = FRAME;
window.pick = (nx = 0, ny = 0) => {
  const ray = new THREE.Raycaster();
  ray.setFromCamera(new THREE.Vector2(nx, ny), camera);
  const hits = ray.intersectObjects(group.children, true);
  return hits.slice(0, 3).map((h) => `${h.object.name || "?"}@${h.distance.toFixed(1)}`);
};
window.proj = (p) => {
  const v = new THREE.Vector3(p[0], p[1], p[2]).project(camera);
  return [((v.x + 1) / 2).toFixed(3), ((1 - v.y) / 2).toFixed(3), v.z.toFixed(2)];
};
window.dbg = () => ({
  cam: camera.position.toArray().map((v) => +v.toFixed(2)),
  target: rig.target.toArray().map((v) => +v.toFixed(2)),
  dist: +rig.dist.toFixed(2),
  azim: +rig.azim.toFixed(4),
  polar: +rig.polar.toFixed(4),
  forward: new THREE.Vector3().setFromMatrixColumn(camera.matrix, 2).negate().toArray().map((v) => +v.toFixed(3)),
  up: new THREE.Vector3().setFromMatrixColumn(camera.matrix, 1).toArray().map((v) => +v.toFixed(3)),
  right: new THREE.Vector3().setFromMatrixColumn(camera.matrix, 0).toArray().map((v) => +v.toFixed(3)),
  fov: camera.fov,
  aspect: +camera.aspect.toFixed(3),
  size: [renderer.domElement.width, renderer.domElement.height],
});

if (READ_ONLY) {
  state.inX = 0;
  state.inY = 0;
  state.amp = 8;
  state.depth = 4;
  state.press = false;
  state.vendor = false;
  state.clip = false;
} else {
  restore();
}
for (const k of ["inX", "inY", "amp", "depth"]) {
  if (params.has(k)) state[k] = +params.get(k);
}
if (params.has("press")) state.press = params.get("press") !== "0";
if (params.has("vendor")) state.vendor = params.get("vendor") !== "0";
if (params.has("bounds")) state.bounds = params.get("bounds") !== "0";
if (params.has("grid")) state.grid = params.get("grid") !== "0";
if (params.has("plane")) state.plane = params.get("plane") !== "0";
if (params.has("pivot")) state.pivot = params.get("pivot") !== "0";
if (params.has("ring")) state.ring = params.get("ring") !== "0";
if (params.has("mirror")) state.mirror = params.get("mirror") !== "0";
setMirror(state.mirror);
readUI();
resize();
goView(params.get("view") || "pad");
if (params.has("dist")) {
  rig.dist = +params.get("dist");
  rig.target.copy(handed(params.get("view") === "full" ? box.getCenter(new THREE.Vector3()) : AXIS_AT_PLANE));
  placeCamera();
}
if (params.has("clip")) setClip(params.get("clip") !== "0");
apply();
document.getElementById("hud").innerHTML =
  '<span class="sw" style="background:#ff8f5a"></span>X 输入转轴　' +
  '<span class="sw" style="background:#59b0ff"></span>Y 输入转轴　' +
  '<span class="sw" style="background:#4cc38a"></span>平面上方　' +
  '<span class="sw" style="background:#e3b341"></span>平面右方';
tick();
