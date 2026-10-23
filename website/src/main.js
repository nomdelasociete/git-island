import "./style.css";
import * as T from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { DRACOLoader } from "three/addons/loaders/DRACOLoader.js";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
const $ = (s) => document.querySelector(s),
  story = $(".journey"),
  stage = $(".stage"),
  desktop = $(".desktop");
const reduce = matchMedia("(prefers-reduced-motion: reduce)"),
  clamp = T.MathUtils.clamp;
// ?capture turns the page into the social card: the scene becomes the
// desktop wallpaper under the island, and the clock stops.
// scripts/capture-social-video.mjs renders each frame through window.capture.
const capturing = new URLSearchParams(location.search).has("capture");
document.body.classList.toggle("capturing", capturing);
let captureView = null,
  anchoredAt = null;
// ponytail: reveal waits on Draco decode of macbook-pro.glb. Shrink that
// file if the spinner stays up; don't add a second loader.
const macbookBytes = fetch("/models/macbook-pro.glb").then((response) => {
  if (!response.ok) throw new Error("Mac model " + response.status);
  return response.arrayBuffer();
});
const macDecoder = new DRACOLoader().setDecoderPath("/draco/");
const macDecoderReady = macDecoder.preload();
const smooth = (a, b, v) => {
  const t = clamp((v - a) / (b - a), 0, 1);
  return t * t * (3 - 2 * t);
};
let targetP = 0,
  currentP = 0,
  scrollProgress = 0,
  elapsed = 0,
  lastTime = 0;
const destination = (p) =>
  story.offsetTop + p * (story.offsetHeight - innerHeight);
document.querySelectorAll("[data-go]").forEach((b) =>
  b.addEventListener("click", () =>
    window.scrollTo({
      top: destination(Number(b.dataset.go)),
      behavior: reduce.matches ? "instant" : "smooth",
    }),
  ),
);
const prs = [
  {
    state: "ready",
    title: "Give the command menu a little polish",
    repo: "studio / canvas",
    number: 42,
    label: "Ready to merge",
  },
  {
    state: "ready",
    title: "Make keyboard shortcuts feel native",
    repo: "studio / canvas",
    number: 38,
    label: "Approved",
  },
  {
    state: "blocked",
    title: "Simplify the export pipeline",
    repo: "studio / toolkit",
    number: 16,
    label: "Changes requested",
  },
  {
    state: "waiting",
    title: "A softer landing for new projects",
    repo: "studio / canvas",
    number: 41,
    label: "Your review",
  },
  {
    state: "testing",
    title: "Speed up the preview renderer",
    repo: "studio / toolkit",
    number: 19,
    label: "Checks running",
  },
];
prs.push(
  {
    state: "blocked",
    title: "Keep the sidebar in place",
    repo: "studio / canvas",
    number: 47,
    label: "Fix failing checks",
  },
  {
    state: "waiting",
    title: "A friendlier first launch",
    repo: "studio / toolkit",
    number: 23,
    label: "Review requested",
  },
  {
    state: "testing",
    title: "Cache previews locally",
    repo: "studio / canvas",
    number: 49,
    label: "Checks running",
  },
);
let changedPR = null;
let expanded = false,
  filter = "all",
  notchBeat = "wait",
  notchOpenedAt = 0,
  userTookIsland = false;
// Values mirror IslandDesignSystem.swift and PullRequestGroup.tint.
const statusColors = {
  ready: "#6ed18f",
  blocked: "#fa736b",
  waiting: "#e89433",
  testing: "#73abf2",
};
const statusGlyph = (state) =>
  `<svg viewBox="0 0 16 16" aria-hidden="true"><g fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${
    {
      ready: '<path d="m3 8 3 3 7-8"/>',
      blocked: '<path d="M8 2v7m0 3v.2"/>',
      waiting: '<circle cx="8" cy="8" r="6"/><path d="M8 4v4l3 2"/>',
      testing:
        '<path d="M13 6a5 5 0 0 0-9-2L2 6m0-3v3h3M3 10a5 5 0 0 0 9 2l2-2m0 3v-3h-3"/>',
    }[state]
  }</g></svg>`;
let confirming = null;
function renderInbox() {
  const list = $("#pr-list");
  const focusedMerge = list.contains(document.activeElement)
    ? document.activeElement.closest("[data-merge]")?.dataset.merge
    : null;
  const selected = prs.filter((pr) => filter === "all" || pr.state === filter);
  $("#pr-list").innerHTML = selected
    .map(
      (
        pr,
      ) => `<div class="pr-row ${pr.state}${pr.number === changedPR ? " just-changed" : ""}">
 <span class="pr-icon ${pr.state}">${statusGlyph(pr.state)}</span>
 <div class="pr-text"><div class="pr-title">${pr.title}</div><div class="pr-meta">${pr.repo.split(" / ").pop()} #${pr.number}<i></i>${pr.label}</div></div>
 ${pr.state === "ready" ? `<button class="merge-demo" data-merge="${pr.number}" aria-label="${confirming === pr.number ? "Confirm simulated merge" : "Simulate merge"}">${confirming === pr.number ? "Confirm" : "Merge"}</button>` : ""}</div>`,
    )
    .join("");
  if (focusedMerge) {
    list.querySelector(`[data-merge="${CSS.escape(focusedMerge)}"]`)?.focus({ preventScroll: true });
  }
  $("#inbox-label").textContent =
    filter === "all"
      ? "Pull requests"
      : filter[0].toUpperCase() + filter.slice(1);
  $("#inbox-count").textContent = selected.length;
  $("#show-all").hidden = filter === "all";
  $("#pr-list").style.height = `${Math.min(5, selected.length) * 68}px`;
  $(".inbox").style.setProperty(
    "--body-height",
    `${56 + Math.min(5, selected.length) * 68}px`,
  );
  document.querySelectorAll("[data-filter]").forEach((b) => {
    const state = b.dataset.filter;
    b.setAttribute("aria-pressed", String(filter === state));
    b.innerHTML =
      statusGlyph(state) +
      `<span>${prs.filter((pr) => pr.state === state).length}</span>`;
  });
  drawOutline();
}
function drawOutline() {
  const el = $(".island-app"),
    svg = $("#status-outline");
  const w = el.offsetWidth,
    h = el.offsetHeight,
    radius = expanded ? 28 : 12;
  svg.setAttribute("viewBox", `-6 0 ${w + 12} ${h + 6}`);
  const total = prs.length;
  let start = 0;
  svg.innerHTML = Object.entries(statusColors)
    .map(([state, color]) => {
      const count = prs.filter((pr) => pr.state === state).length,
        share = (count / total) * 100;
      const paths = Array.from(
        { length: expanded ? 1 : Math.min(count, 5) },
        (_, i) => {
          const inset = 2.25 - i * 2.5,
            l = inset,
            right = w - inset,
            bottom = h - inset,
            r = Math.max(0, radius - inset);
          return `<path d="M${l} 0V${bottom - r}Q${l} ${bottom} ${l + r} ${bottom}H${right - r}Q${right} ${bottom} ${right} ${bottom - r}V0" fill="none" stroke="${color}" stroke-width="1.5" pathLength="100" stroke-dasharray="${share} ${100 - share}" stroke-dashoffset="${-start}"/>`;
        },
      ).join("");
      start += share;
      return paths;
    })
    .join("");
}
new ResizeObserver(drawOutline).observe($(".island-app"));
$("#show-all").addEventListener("click", () => {
  filter = "all";
  renderInbox();
});
$("#pr-list").addEventListener("click", (e) => {
  const button = e.target.closest("[data-merge]");
  if (!button) return;
  const id = Number(button.dataset.merge);
  if (confirming !== id) {
    confirming = id;
    renderInbox();
    return;
  }
  prs.splice(
    prs.findIndex((pr) => pr.number === id),
    1,
  );
  confirming = null;
  renderInbox();
});
function openInbox(value = true) {
  expanded = value;
  if (!value) confirming = null;
  $(".inbox").inert = !value;
  document
    .querySelectorAll("[data-filter]")
    .forEach((b) => (b.disabled = !value));
  $(".island-app").classList.toggle("expanded", value);
  drawOutline();
  desktop.classList.toggle("has-open", value);
  $(".notch-toggle").setAttribute("aria-expanded", String(value));
  $(".notch-toggle").setAttribute(
    "aria-label",
    value ? "Collapse Git Island" : "Expand Git Island",
  );
}
$(".notch-toggle").addEventListener("click", () => {
  userTookIsland = true;
  filter = "all";
  renderInbox();
  openInbox(!expanded);
});
$(".notch-toggle").addEventListener("mouseenter", () => {
  if (matchMedia("(hover: hover)").matches) {
    filter = "all";
    renderInbox();
    openInbox();
  }
});
$("#try-demo").addEventListener("click", () => {
  userTookIsland = true;
  filter = "all";
  renderInbox();
  openInbox();
  $(".notch-toggle").focus({ preventScroll: true });
});
document.querySelectorAll("[data-filter]").forEach((b) =>
  b.addEventListener("click", () => {
    userTookIsland = true;
    const same = expanded && filter === b.dataset.filter;
    filter = b.dataset.filter;
    renderInbox();
    openInbox(!same);
  }),
);
desktop.addEventListener("click", (e) => {
  if (
    !e.composedPath().includes($(".island-app")) &&
    !e.target.closest("#try-demo")
  )
    openInbox(false);
});
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") openInbox(false);
});
let activityTime = 0,
  eventIndex = 0;
const events = [
  [19, "ready", "Checks passed"],
  [47, "testing", "Fix pushed · checking"],
  [41, "ready", "Review approved"],
  [49, "blocked", "Check needs attention"],
  [19, "testing", "New commit · checking"],
  [47, "blocked", "Changes requested"],
  [41, "waiting", "Your review"],
  [49, "testing", "Fix pushed · checking"],
];
let leaveTimer;
$(".island-app").addEventListener("mouseenter", () => clearTimeout(leaveTimer));
$(".island-app").addEventListener("mouseleave", () => {
  if (notchBeat === "open" && !userTookIsland) return;
  leaveTimer = setTimeout(() => openInbox(false), 280);
});
document.querySelectorAll("[data-filter]").forEach((b) =>
  b.addEventListener("mouseenter", () => {
    if (expanded && matchMedia("(hover:hover)").matches) {
      filter = b.dataset.filter;
      renderInbox();
    }
  }),
);
renderInbox();
openInbox(false);
let renderer, scene, camera, ocean;
const interactiveActors = [];
const trees = [];
const platformCenter = { x: 0.8, z: 0.65 };
const platformRadius = (x, z) =>
  Math.hypot((x - platformCenter.x) / 2.8, (z - platformCenter.z) / 2.184);
const boatPosition = (t) => {
  const a = (anchoredAt ?? t) * 0.025 + 1.25;
  return { x: 3 + Math.cos(a) * 8.1, z: Math.sin(a) * 6.4, a };
};
const impulse = (actor, t) => {
  const age = t - (actor.userData.tappedAt ?? -100);
  return age >= 0 && age < 3 ? Math.sin(age * 9) * Math.exp(-age * 1.8) : 0;
};
let seed = 831;
function random() {
  seed = (1664525 * seed + 1013904223) >>> 0;
  return seed / 4294967296;
}
const mat = (color, roughness = 0.8, metalness = 0) =>
  new T.MeshStandardMaterial({ color, roughness, metalness });
const stoneMat = mat("#68716c"),
  trunkMat = mat("#595a44"),
  foliage = [mat("#304f42"), mat("#46604b"), mat("#607859")];
function height(x, z) {
  const a = Math.atan2(z, x),
    r = Math.sqrt((x / 1.15) ** 2 + (z / 0.9) ** 2),
    coast = 5.1 + 0.5 * Math.sin(a * 3 + 0.7) + 0.3 * Math.cos(a * 5);
  const inland = coast - r;
  const base = Math.max(0, inland / coast);
  const ridge = 1.85 * Math.exp(-((x + 1.5) ** 2 / 4 + (z + 1.5) ** 2 / 2));
  // A continuous beach crosses the water plane, rather than ending in a cliff.
  const terrain = -0.18 + 1.45 * Math.pow(base, 0.65) +
    ridge * smooth(0, 1.3, inland) +
    (Math.sin(x * 3.2 + z * 2) * 0.1 + Math.cos(z * 4.1 - x) * 0.07) *
      smooth(0, 1.5, inland);
  // The entire plinth footprint rests on one level clearing, blended into the hill.
  const clearing = 1 - smooth(1, 1.3, platformRadius(x, z));
  return T.MathUtils.lerp(terrain, 1.2, clearing);
}
function mesh(geo, material, parent = scene) {
  const m = new T.Mesh(geo, material);
  m.castShadow = true;
  m.receiveShadow = true;
  parent.add(m);
  return m;
}
function tree(x, z, size, parent) {
  const y = height(x, z);
  if (y < 0.5 || (x > -1.8 && x < 3.8 && z > -2.0 && z < 3.6)) return;
  const g = new T.Group();
  g.position.set(x, y, z);
  g.scale.setScalar(size);
  parent.add(g);
  interactiveActors.push(g);
  trees.push(g);
  mesh(new T.CylinderGeometry(0.035, 0.065, 0.8, 6), trunkMat, g).position.y =
    0.35;
  for (let i = 0; i < 3; i++) {
    const c = mesh(
      new T.ConeGeometry(0.38 - i * 0.08, 0.8 - i * 0.08, 7),
      foliage[i],
      g,
    );
    c.position.y = 0.7 + i * 0.28;
    c.rotation.y = random() * 3;
  }
}
function wallpaper() {
  const c = document.createElement("canvas");
  c.width = 1545;
  c.height = 1000;
  const ctx = c.getContext("2d");
  const bg = ctx.createLinearGradient(0, 0, 1600, 1000);
  bg.addColorStop(0, "#203b61");
  bg.addColorStop(0.5, "#627ca5");
  bg.addColorStop(1, "#b7a5b9");
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, 1600, 1000);
  for (let i = 0; i < 6; i++) {
    const y = 300 + i * 140,
      fill = ctx.createLinearGradient(0, y, 1000, 1000);
    fill.addColorStop(
      0,
      ["#bacfce", "#92b2bd", "#779bb4", "#456a99", "#294a77", "#18365f"][i],
    );
    fill.addColorStop(1, "#203f6a");
    ctx.fillStyle = fill;
    ctx.beginPath();
    ctx.moveTo(0, y + 420);
    ctx.bezierCurveTo(420, y - 350, 1000, y + 500, 1600, y - 180);
    ctx.lineTo(1600, 1000);
    ctx.lineTo(0, 1000);
    ctx.fill();
  }
  c.toBlob((blob) => {
    if (blob)
      desktop.style.backgroundImage = `url(${URL.createObjectURL(blob)})`;
  });
  const texture = new T.CanvasTexture(c);
  texture.colorSpace = T.SRGBColorSpace;
  texture.anisotropy = 4;
  return texture;
}
const sharedWallpaper = wallpaper();
function makeDevice(parent) {
  const loader = new GLTFLoader().setDRACOLoader(macDecoder);
  Promise.all([macbookBytes, macDecoderReady])
    .then(
      ([buffer]) =>
        new Promise((resolve, reject) => {
          loader.parse(buffer, "/models/", resolve, reject);
        }),
    )
    .then(({ scene: model }) => {
      const bounds = new T.Box3().setFromObject(model),
        size = bounds.getSize(new T.Vector3());
      const scale = 3.9 / size.x;
      model.scale.setScalar(scale);
      const center = bounds.getCenter(new T.Vector3());
      model.position.set(
        0.8 - center.x * scale,
        1.48 - bounds.min.y * scale,
        0.65 - center.z * scale,
      );
      model.traverse((m) => {
        if (m.isMesh) {
          m.castShadow = true;
          m.receiveShadow = true;
        }
      });
      // The card is the Mac's own screen; no Mac inside its wallpaper.
      model.visible = !capturing;
      parent.add(model);
      renderer.shadowMap.needsUpdate = true;
      const screen = model.getObjectByName("Object_123");
      if (screen) {
        const texture = sharedWallpaper;
        texture.flipY = true;
        screen.material = new T.MeshBasicMaterial({
          map: texture,
          toneMapped: false,
          fog: false,
        });
      }
      document.body.dataset.model = "loaded";
      macDecoder.dispose();
    })
    .catch(() => {
      document.body.dataset.model = "failed";
      macDecoder.dispose();
    });
}
const seaActors = [];
const waterContacts = {
  sail: { value: new T.Vector4(100, 100, 0, 0) },
  whale: { value: new T.Vector4(100, 100, 0, 0) },
  tap: { value: new T.Vector4(100, 100, 10, 0) },
  splash: { value: new T.Vector4(100, 100, 10, 0) },
};
function makeSeaLife() {
  const loader = new GLTFLoader();
  const specs = [
    { file: "boat-sail", length: 1.2, phase: 2.1 },
    { file: "whale", length: 2.3, phase: 0 },
  ];
  document.body.dataset.seaModels = "0";
  for (const spec of specs)
    loader.load(`/models/${spec.file}.glb`, ({ scene: model, animations }) => {
      const bounds = new T.Box3().setFromObject(model);
      const size = bounds.getSize(new T.Vector3()),
        center = bounds.getCenter(new T.Vector3());
      const scale = spec.length / Math.max(size.x, size.z);
      model.scale.setScalar(scale);
      model.position.set(
        -center.x * scale,
        -bounds.min.y * scale,
        -center.z * scale,
      );
      const actor = new T.Group();
      actor.add(model);
      scene.add(actor);
      model.traverse((m) => {
        m.castShadow = false;
        m.receiveShadow = false;
      });
      if (spec.file === "whale") {
        const mixer = new T.AnimationMixer(model);
        animations.forEach((clip) => mixer.clipAction(clip).play());
        const drops = new T.InstancedMesh(
          new T.SphereGeometry(0.022, 6, 4),
          new T.MeshBasicMaterial({
            color: "#e9fffa",
            transparent: true,
            opacity: 0.8,
          }),
          32,
        );
        drops.frustumCulled = false;
        scene.add(drops);
        const droplet = new T.Object3D();
        seaActors.push((t) => {
          mixer.setTime(t * 0.55);
          const a = t * 0.035;
          const x = 2.5 + Math.sin(a) * 3.3,
            z = 6.4 + Math.cos(a) * 0.5;
          const heading = Math.atan2(3.3 * Math.cos(a), -0.5 * Math.sin(a));
          // Most of the body stays below the opaque water; only the back
          // breaks the surface on the breathing part of the swim cycle.
          const cycle = (t + 2) % 16;
          const surface = smooth(0, 2, cycle) * (1 - smooth(5, 9, cycle));
          const age = cycle - 2;
          const eventTime = t - age;
          const splashX = 2.5 + Math.sin(eventTime * 0.035) * 3.3;
          const splashZ = 6.4 + Math.cos(eventTime * 0.035) * 0.5;
          waterContacts.splash.value.set(
            splashX,
            splashZ,
            Math.max(0, age),
            age >= 0 && age < 5 ? 1 : 0,
          );
          for (let i = 0; i < 32; i++) {
            const flight = age - (i % 5) * 0.06;
            const angle = i * 2.39996;
            const speed = 0.35 + (i % 7) * 0.055;
            const y =
              0.04 + (1.55 + (i % 6) * 0.12) * flight - 2.5 * flight * flight;
            const visible = flight >= 0 && flight < 1.2 && y > 0.02;
            droplet.position.set(
              splashX + Math.cos(angle) * speed * flight,
              Math.max(0.02, y),
              splashZ + Math.sin(angle) * speed * flight,
            );
            droplet.scale.setScalar(
              visible ? Math.max(0.1, 1 - flight * 0.5) : 0,
            );
            droplet.updateMatrix();
            drops.setMatrixAt(i, droplet.matrix);
          }
          drops.instanceMatrix.needsUpdate = true;
          // Dive before entering the boat's safety envelope, including when anchored.
          const boat = boatPosition(t);
          const clearance = smooth(2.2, 3.8, Math.hypot(x - boat.x, z - boat.z));
          const visibleSurface = surface * clearance;
          drops.visible = clearance > 0.99;
          waterContacts.splash.value.w *= clearance > 0.99 ? 1 : 0;
          actor.position.set(
            x,
            -size.y * scale * (1.1 - 0.32 * visibleSurface) - 0.6 * (1 - clearance),
            z,
          );
          actor.rotation.set(0, heading + Math.PI / 2, 0);
          waterContacts.whale.value.set(x, z, heading, visibleSurface);
        });
      } else {
        interactiveActors.push(actor);
        seaActors.push((t) => {
          // An anchored boat still rocks; only its course stops.
          const { x, z, a } = boatPosition(t);
          const nudge = impulse(actor, t);
          const heading = Math.atan2(-8.1 * Math.sin(a), 6.4 * Math.cos(a));
          const swell = Math.sin(x * 0.8 + z * 0.6 + t * 0.8);
          // Waterline is measured from the keel, not the whole model's
          // height (which includes the sail). Motion follows the hull's path.
          actor.position.set(x, -spec.length * 0.075 + swell * 0.004, z);
          actor.rotation.set(
            Math.cos(t * 0.8 + spec.phase) * 0.004,
            heading,
            Math.sin(t * 0.7 + spec.phase) * 0.006 + nudge * 0.16,
          );
          waterContacts.sail.value.set(x, z, heading, 1);
          const age = t - (actor.userData.tappedAt ?? -100);
          waterContacts.tap.value.z = age;
          waterContacts.tap.value.w = age >= 0 && age < 3 ? 1 : 0;
        });
      }
      document.body.dataset.seaModels = String(
        Number(document.body.dataset.seaModels) + 1,
      );
    });
}
function initScene() {
  renderer = new T.WebGLRenderer({
    antialias: true,
    powerPreference: "high-performance",
  });
  renderer.setPixelRatio(Math.min(Math.max(devicePixelRatio, 1.5), 2));
  renderer.setSize(innerWidth, innerHeight);
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = T.PCFShadowMap;
  renderer.shadowMap.autoUpdate = false;
  renderer.shadowMap.needsUpdate = true;
  renderer.toneMapping = T.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.0;
  $("#scene").append(renderer.domElement);
  scene = new T.Scene();
  scene.background = new T.Color("#dce6e7");
  scene.fog = new T.FogExp2("#dce6e7", 0.012);
  camera = new T.PerspectiveCamera(38, innerWidth / innerHeight, 0.08, 180);
  const pmrem = new T.PMREMGenerator(renderer),
    room = new RoomEnvironment();
  scene.environment = pmrem.fromScene(room, 0.04).texture;
  scene.environmentIntensity = 0.4;
  room.dispose();
  pmrem.dispose();
  scene.add(new T.HemisphereLight("#ebf2ff", "#546a59", 0.9));
  const sun = new T.DirectionalLight("#fff0db", 2.0);
  sun.position.set(-8, 16, 7);
  sun.castShadow = true;
  sun.shadow.mapSize.set(2048, 2048);
  Object.assign(sun.shadow.camera, {
    left: -12,
    right: 12,
    top: 12,
    bottom: -12,
  });
  sun.shadow.bias = -0.0006;
  sun.shadow.normalBias = 0.05;
  scene.add(sun);
  const island = new T.Group();
  island.position.x = 3;
  scene.add(island);
  const geo = new T.PlaneGeometry(13, 12, 120, 110);
  geo.rotateX(-Math.PI / 2);
  const positions = geo.attributes.position,
    colors = [],
    color = new T.Color();
  for (let i = 0; i < positions.count; i++) {
    const x = positions.getX(i),
      z = positions.getZ(i),
      y = height(x, z);
    positions.setY(i, y);
    color.set(
      y < 0.19
        ? "#b7bba1"
        : y < 0.55
          ? "#899383"
          : y > 2.05
            ? "#536351"
            : "#74866a",
    );
    color.offsetHSL(0, 0, Math.sin(x * 51 + z * 27) * Math.cos(z * 41) * 0.035);
    colors.push(color.r, color.g, color.b);
  }
  geo.setAttribute("color", new T.Float32BufferAttribute(colors, 3));
  geo.computeVertexNormals();
  mesh(
    geo,
    new T.MeshStandardMaterial({ vertexColors: true, roughness: 0.98 }),
    island,
  );
  for (let i = 0; i < 95; i++)
    tree(
      (random() - 0.5) * 9,
      (random() - 0.5) * 7,
      0.5 + random() * 0.75,
      island,
    );
  for (let i = 0; i < 65; i++) {
    const a = random() * Math.PI * 2,
      r = 3 + random() * 2.2,
      x = Math.cos(a) * r * 1.1,
      z = Math.sin(a) * r * 0.85,
      y = height(x, z);
    if (y < -0.1 || platformRadius(x, z) < 1.2) continue;
    const rock = mesh(
      new T.DodecahedronGeometry(0.15 + random() * 0.3),
      stoneMat,
      island,
    );
    rock.position.set(x, y - 0.05, z);
    rock.scale.set(1.3, 0.6 + random(), 1);
    rock.rotation.set(random(), random(), random());
  }
  const platform = mesh(
    new T.CylinderGeometry(2.6, 2.8, 0.3, 64),
    mat("#a5aa95"),
    island,
  );
  platform.position.set(platformCenter.x, 1.33, platformCenter.z);
  platform.scale.z = 0.78;
  platform.visible = !capturing;
  makeDevice(island);
  makeSeaLife();
  const waterGeo = new T.PlaneGeometry(2000, 2000);
  waterGeo.rotateX(-Math.PI / 2);
  ocean = new T.Mesh(
    waterGeo,
    new T.ShaderMaterial({
      uniforms: { time: { value: 0 }, ...waterContacts },
      vertexShader:
        "varying vec3 world; void main(){world=(modelMatrix*vec4(position,1.)).xyz;gl_Position=projectionMatrix*viewMatrix*vec4(world,1.);}",
      fragmentShader: [
        `varying vec3 world;
        uniform float time; uniform vec4 sail; uniform vec4 whale; uniform vec4 splash; uniform vec4 tap;
        vec2 contactUV(vec4 c){
          vec2 d=world.xz-c.xy; vec2 f=vec2(sin(c.z),cos(c.z));
          return vec2(dot(d,vec2(f.y,-f.x)),dot(d,f));
        }
        float wake(vec4 c){
          vec2 q=contactUV(c);float aft=-q.y;
          float trail=smoothstep(.4,.8,aft)*(1.-smoothstep(1.,3.8,aft));
          float edges=exp(-pow((abs(q.x)-(.16+aft*.19))*15.,2.));
          float foam=.6+.4*sin(aft*21.+time*2.5+q.x*9.);
          float bow=exp(-pow((length(q/vec2(.29,.73))-1.)*14.,2.))*.12;
          return (edges*trail*foam*.11+bow)*c.w;
        }
        float hullShadow(vec4 c){vec2 q=contactUV(c);return exp(-dot(q/vec2(.4,.9),q/vec2(.4,.9)))*c.w;}
        void main(){`,
        "vec2 p=world.xz-vec2(3.,0.);float a=atan(p.y,p.x);float r=length(vec2(p.x/1.15,p.y/.9));",
        "float coast=5.1+.5*sin(a*3.+.7)+.3*cos(a*5.);float waterline=coast*(1.-pow(.195/1.45,1./.65));float shore=r-waterline;",
        "vec3 col=mix(vec3(.58,.76,.71),vec3(.43,.62,.64),smoothstep(0.,5.,shore));",
        "float phase=shore*7.-time*.8;float aa=1.-smoothstep(.4,2.,fwidth(phase));",
        "float waves=pow(.5+.5*sin(phase),6.);",
        "col+=waves*aa*exp(-max(0.,shore)*1.8)*smoothstep(-.05,.2,shore)*.065;",
        "col+=exp(-pow(shore/.12,2.))*.055;",
        "col+=sin(world.x*2.+world.z*1.6+time*.65)*sin(world.z*2.4-time*.46)*.004;",
        `col=mix(col,vec3(.863,.902,.906),smoothstep(10.,45.,length(p)));
        col-=vec3(.055,.04,.025)*hullShadow(sail);
        col+=vec3(.75,.87,.83)*wake(sail);
        vec2 w=contactUV(whale);
        float body=exp(-dot(w/vec2(.36,1.2),w/vec2(.36,1.2)));
        col=mix(col,col*vec3(.8,.9,.95),body*.6*whale.w);
        float rings=length(w/vec2(.5,1.5));
        float ripple=pow(.5+.5*sin(rings*23.-time*1.3),12.)*exp(-max(0.,rings-1.)*3.)*smoothstep(.8,1.1,rings);
        col+=ripple*whale.w*.065;
        float distanceToSplash=length(world.xz-splash.xy);
        float impact=0.;
        for(int i=0;i<3;i++) {
          float age=splash.z-float(i)*.23;
          float radius=.15+age*.65;
          float ring=exp(-pow((distanceToSplash-radius)*22.,2.));
          impact+=ring*step(0.,age)*(1.-smoothstep(1.,4.5,age));
        }
        col+=vec3(.65,.8,.78)*impact*splash.w*.18;
        float tapDistance=length(world.xz-tap.xy);
        float tapWidth=max(.06,fwidth(tapDistance)*1.5);
        float tapRing=exp(-pow((tapDistance-(.4+tap.z*.8))/tapWidth,2.));
        col+=tapRing*tap.w*(1.-smoothstep(0.,3.,tap.z))*.1;
        gl_FragColor=vec4(col,1.);}`,
      ].join(""),
    }),
  );
  ocean.position.y = 0.015;
  scene.add(ocean);
  const raycaster = new T.Raycaster();
  const pointer = new T.Vector2();
  const pick = (event) => {
    if (reduce.matches || currentP > 0.65 || event.target !== renderer.domElement) return null;
    const rect = renderer.domElement.getBoundingClientRect();
    pointer.set((event.clientX - rect.left) / rect.width * 2 - 1,
      -(event.clientY - rect.top) / rect.height * 2 + 1);
    raycaster.setFromCamera(pointer, camera);
    // Include the terrain and device so hidden trees cannot be clicked through them.
    const hit = raycaster.intersectObjects(scene.children, true)[0];
    let object = hit?.object;
    while (object) {
      if (interactiveActors.includes(object)) return object;
      object = object.parent;
    }
    return null;
  };
  renderer.domElement.addEventListener("pointermove", (event) => {
    renderer.domElement.style.cursor = pick(event) ? "pointer" : "";
  });
  renderer.domElement.addEventListener("click", (event) => {
    const actor = pick(event);
    if (!actor || elapsed - (actor.userData.tappedAt ?? -100) < 0.45) return;
    actor.userData.tappedAt = elapsed;
    if (!trees.includes(actor)) {
      waterContacts.tap.value.set(actor.position.x, actor.position.z, 0, 1);
    }
  });
}
try {
  initScene();
} catch (error) {
  renderer = null;
  document.body.classList.add("no-webgl");
  $("#scene").replaceChildren();
  console.warn("Using lightweight preview:", error.message);
}
function updateScroll() {
  scrollProgress = clamp(
    (scrollY - story.offsetTop) / (story.offsetHeight - innerHeight),
    0,
    1,
  );
  targetP = reduce.matches ? 0.93 : scrollProgress;
}
addEventListener("scroll", updateScroll, { passive: true });
addEventListener("resize", () => {
  if (renderer) {
    renderer.setSize(innerWidth, innerHeight);
    camera.aspect = innerWidth / innerHeight;
    camera.updateProjectionMatrix();
  }
  updateScroll();
});
reduce.addEventListener("change", updateScroll);
updateScroll();
function frame(time) {
  if (!capturing) requestAnimationFrame(frame);
  const dt = Math.min((time - lastTime) / 1000, 0.15);
  lastTime = time;
  if (document.hidden) return;
  elapsed += reduce.matches ? 0 : dt;
  currentP +=
    (targetP - currentP) * (reduce.matches ? 1 : 1 - Math.exp(-dt * 9));
  const p = currentP,
    mobile = innerWidth < 760,
    op = 1 - smooth(0.07, 0.27, p);
  $(".intro").style.opacity = op;
  $(".intro").style.transform = "translateY(" + -p * 90 + "px)";
  $(".intro").inert = op < 0.1;
  $(".device-copy").style.opacity =
    smooth(0.25, 0.37, p) * (1 - smooth(0.53, 0.66, p));
  const demo = reduce.matches ? 1 : smooth(0.74, 0.82, p);
  desktop.style.opacity = demo;
  desktop.style.visibility = demo > 0.001 ? "visible" : "hidden";
  desktop.inert = demo < 0.95;
  const controls = reduce.matches ? 1 : smooth(0.9, 0.96, p);
  const displayHeight = Math.min(2.446, 3.779 / (innerWidth / innerHeight));
  const notchScale =
    (0.406 * innerHeight) / displayHeight / (mobile ? 145 : 210);
  desktop.style.setProperty(
    "--notch-scale",
    T.MathUtils.lerp(notchScale, 1, controls),
  );
  $(".vignette").style.opacity = 1 - smooth(0.67, 0.83, p);
  if (p < 0.68 && notchBeat !== "wait") {
    notchBeat = "wait";
    userTookIsland = false;
    openInbox(false);
  } else if (!reduce.matches && notchBeat === "wait" && demo >= 0.95) {
    notchBeat = "open";
    notchOpenedAt = time;
    filter = "all";
    renderInbox();
    openInbox(true);
  } else if (
    notchBeat === "open" &&
    !userTookIsland &&
    time - notchOpenedAt > 2400
  ) {
    openInbox(false);
    notchBeat = "done";
  }
  if (
    demo > 0.95 &&
    expanded &&
    !reduce.matches &&
    scrollY <= destination(1)
  ) {
    activityTime += dt;
    if (activityTime > 5.5) {
      activityTime = 0;
      const [id, state, label] = events[eventIndex++ % events.length];
      const changed = prs.find((pr) => pr.number === id);
      if (changed) Object.assign(changed, { state, label });
      changedPR = id;
      renderInbox();
    }
  }
  stage.classList.toggle("in-demo", demo > 0.5 && scrollY <= destination(1));
  $("#progress").style.width = scrollProgress * 100 + "%";
  $(".skip").style.visibility = p > 0.8 ? "hidden" : "visible";
  $("#scroll-label").textContent =
    p > 0.85 ? "Scroll for more" : "Scroll to explore";
  if (!renderer || reduce.matches || scrollY > story.offsetHeight || demo >= 1)
    return;
  const wide = mobile ? new T.Vector3(14, 16, 32) : new T.Vector3(12, 11, 20),
    look = mobile ? new T.Vector3(3, 6.1, 0) : new T.Vector3(-1.8, 1, 0);
  const mid = mobile ? new T.Vector3(7, 6.6, 10) : new T.Vector3(7.3, 5.5, 9),
    midLook = mobile
      ? new T.Vector3(3.8, 2.6, 0.4)
      : new T.Vector3(2.3, 2.5, 0.5);
  // Finish perpendicular to the model's tilted display. The screen must
  // cover the viewport before handing the same wallpaper to HTML.
  const closeLook = new T.Vector3(3.8, 2.8885, -0.7237);
  const screenNormal = new T.Vector3(0, 0.342, 0.94).normalize();
  const coverDistance =
    Math.min(2.446, 3.779 / camera.aspect) /
    (2 * Math.tan(T.MathUtils.degToRad(camera.fov / 2)));
  const close = closeLook.clone().addScaledVector(screenNormal, coverDistance);
  camera.up
    .set(0, 1, 0)
    .lerp(new T.Vector3(0, 0.94, -0.342).normalize(), smooth(0.48, 0.7, p));
  let aim;
  if (captureView) {
    camera.up.set(0, 1, 0);
    camera.position.fromArray(captureView.position);
    aim = new T.Vector3().fromArray(captureView.look);
  } else if (p < 0.48) {
    const t = smooth(0.03, 0.48, p);
    camera.position.copy(wide).lerp(mid, t);
    aim = look.lerp(midLook, t);
  } else {
    const t = smooth(0.48, 0.7, p);
    camera.position.copy(mid).lerp(close, t);
    aim = midLook.lerp(closeLook, t);
  }
  camera.lookAt(aim);
  ocean.material.uniforms.time.value = elapsed;
  seaActors.forEach((update) => update(elapsed));
  let movingTrees = false;
  trees.forEach((tree) => {
    const bend = impulse(tree, elapsed);
    movingTrees ||= bend !== 0 || tree.rotation.z !== 0;
    tree.rotation.z = bend * 0.12;
    tree.rotation.x = bend * 0.045;
  });
  if (movingTrees) renderer.shadowMap.needsUpdate = true;
  renderer.render(scene, camera);
}
if (!capturing) requestAnimationFrame(frame);
else {
  // CSS transitions and keyframes follow the capture clock too: each one is
  // paused and placed by how long ago, in capture time, it started. Changes
  // made between two frames count from the earlier one.
  const started = new WeakMap();
  let captureTime = 0;
  const hold = (time) => {
    for (const animation of document.getAnimations()) {
      if (!started.has(animation)) started.set(animation, time);
      animation.pause();
      animation.currentTime = captureTime - started.get(animation);
    }
  };
  window.capture = {
    ready: Promise.all([
      document.fonts.ready,
      new Promise((resolve) => {
        const check = () =>
          document.body.dataset.model && document.body.dataset.seaModels === "2"
            ? resolve()
            : setTimeout(check, 50);
        check();
      }),
    ]),
    start({ seaTime = 0, anchor = null, view }) {
      elapsed = seaTime;
      anchoredAt = anchor;
      captureView = view;
    },
    open(value) {
      filter = "all";
      renderInbox();
      openInbox(value);
    },
    status(id, state, label) {
      Object.assign(
        prs.find((pr) => pr.number === id),
        { state, label },
      );
      changedPR = id;
      renderInbox();
    },
    frame(seconds) {
      hold(captureTime);
      captureTime = seconds * 1000;
      frame(captureTime);
      hold(captureTime);
    },
  };
}
