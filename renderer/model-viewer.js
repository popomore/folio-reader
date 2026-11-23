import {
  Box3, Color, DirectionalLight, HemisphereLight, PerspectiveCamera, Scene,
  Sphere, Vector3, WebGLRenderer,
} from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";
import { MAX_MODEL_BYTES, parseModel } from "./model-loader.js";

let renderer, scene, camera, controls, model, bounds, frame;
let disposed = false;
const canvas = document.querySelector("canvas");
const status = document.querySelector("#status");
const toolbar = document.querySelector("nav");
const wireframe = document.querySelector("#wireframe");

function report(state, detail = {}) {
  window.folioModelState = { state, ...detail };
  window.webkit?.messageHandlers.folioModel?.postMessage(window.folioModelState);
}

function render() {
  frame = undefined;
  if (!disposed) renderer?.render(scene, camera);
}

function invalidate() {
  if (disposed) return;
  if (frame === undefined) frame = requestAnimationFrame(render);
}

function resize() {
  if (!renderer || disposed) return;
  const { width, height } = canvas.getBoundingClientRect();
  renderer.setSize(Math.max(1, width), Math.max(1, height), false);
  camera.aspect = Math.max(1, width) / Math.max(1, height);
  camera.updateProjectionMatrix();
  invalidate();
}

function reset() {
  if (!bounds || disposed) return;
  const { radius } = bounds.getBoundingSphere(new Sphere());
  const halfFov = camera.fov * Math.PI / 360;
  const distance = radius / Math.sin(Math.min(halfFov, Math.atan(Math.tan(halfFov) * camera.aspect))) * 1.15;
  camera.near = Math.max(distance / 10_000, 0.00001);
  camera.far = distance * 100;
  camera.position.copy(new Vector3(1, 0.75, 1).normalize().multiplyScalar(distance));
  camera.updateProjectionMatrix();
  controls.target.set(0, 0, 0);
  controls.minDistance = radius * 0.02;
  controls.maxDistance = distance * 20;
  controls.update();
  invalidate();
}

function setWireframe(enabled) {
  model?.traverse((node) => {
    for (const material of node.material ? [node.material].flat() : []) {
      material.wireframe = enabled;
    }
  });
  wireframe.setAttribute("aria-pressed", String(enabled));
  invalidate();
}

window.folioModelAppearance = (scheme, colors = {}) => {
  document.documentElement.dataset.colorScheme = scheme;
  for (const [key, value] of Object.entries(colors)) document.documentElement.style.setProperty(key, value);
  if (scene) {
    scene.background = new Color(getComputedStyle(document.documentElement).getPropertyValue("--paper").trim());
    invalidate();
  }
};

window.folioLoadModel = async (url, name, scheme, colors, snapshot = false) => {
  try {
    report("loading");
    const response = await fetch(url);
    if (!response.ok) throw new Error("The model file could not be read.");
    if (Number(response.headers.get("Content-Length")) > MAX_MODEL_BYTES) throw new Error("This model exceeds the 128 MiB preview limit.");
    const parsed = await parseModel(await response.arrayBuffer(), name, new URL(".", url).href);
    if (disposed) return;
    model = parsed.object;
    scene = new Scene();
    const originalBounds = new Box3().setFromObject(model);
    const size = originalBounds.getSize(new Vector3());
    if (![size.x, size.y, size.z].every(Number.isFinite) || size.length() <= 0) {
      throw new Error("This model has no visible dimensions.");
    }
    model.position.sub(originalBounds.getCenter(new Vector3()));
    // Normalize the camera space while retaining the original dimensions for the reader.
    model.scale.multiplyScalar(2 / Math.max(size.x, size.y, size.z));
    model.position.multiplyScalar(2 / Math.max(size.x, size.y, size.z));
    model.updateMatrixWorld(true);
    scene.add(model);
    bounds = new Box3().setFromObject(model);
    scene.add(new HemisphereLight(0xffffff, 0x586777, 2.4));
    const key = new DirectionalLight(0xffffff, 3.1);
    key.position.set(3, 5, 4);
    scene.add(key);
    const fill = new DirectionalLight(0xdcecff, 1.2);
    fill.position.set(-3, 1, -2);
    scene.add(fill);
    renderer = new WebGLRenderer({ canvas, antialias: true, preserveDrawingBuffer: snapshot });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    camera = new PerspectiveCamera(40, 1, 0.001, 100);
    controls = new OrbitControls(camera, canvas);
    controls.addEventListener("change", invalidate);
    controls.listenToKeyEvents(canvas);
    resize();
    reset();
    window.folioModelAppearance(scheme, colors);
    const dimensions = [size.x, size.y, size.z].map((v) => Number(v.toPrecision(4))).join(" × ");
    const countLabel = (count, label) => `${count.toLocaleString()} ${label}${count === 1 ? "" : "s"}`;
    status.textContent = `${countLabel(parsed.meshes, "part")} · ${countLabel(parsed.triangles, "triangle")} · ${dimensions} ${parsed.unit}`;
    document.querySelector("#note").textContent = parsed.note;
    toolbar.hidden = false;
    canvas.hidden = false;
    if (snapshot) {
      render();
    } else {
      await new Promise(requestAnimationFrame);
      render();
    }
    if (!disposed && window.folioModelState.state !== "error") {
      report("ready", { meshes: parsed.meshes, triangles: parsed.triangles, dimensions, unit: parsed.unit });
    }
  } catch (error) {
    const message = error instanceof RangeError ? "This model is invalid or too large to preview."
      : error instanceof Error ? error.message : "This model could not be opened.";
    status.textContent = message;
    report("error", { message });
  }
};

window.folioModelSnapshot = () => {
  if (disposed) throw new Error("This 3D preview has closed.");
  render();
  const gl = renderer.getContext();
  const width = gl.drawingBufferWidth, height = gl.drawingBufferHeight;
  if (gl.isContextLost() || !width || !height || width * height > 4_194_304) {
    throw new Error("The 3D preview could not be captured.");
  }
  // Read the rendered framebuffer directly; native code owns PNG encoding.
  const pixels = new Uint8Array(width * height * 4);
  gl.readPixels(0, 0, width, height, gl.RGBA, gl.UNSIGNED_BYTE, pixels);
  if (gl.isContextLost() || gl.getError() !== gl.NO_ERROR) throw new Error("The 3D preview could not be captured.");
  let binary = "";
  for (let offset = 0; offset < pixels.length; offset += 0x8000) {
    binary += String.fromCharCode(...pixels.subarray(offset, offset + 0x8000));
  }
  return { width, height, rgba: btoa(binary) };
};
window.folioModelReset = reset;
window.folioModelViewState = () => ({
  position: camera.position.toArray(), target: controls.target.toArray(),
  aspect: camera.aspect, near: camera.near, far: camera.far, disposed,
});
window.folioModelDispose = () => {
  // The native host owns the renderer's lifetime, including hidden previews.
  if (disposed) return;
  disposed = true;
  resizeObserver.disconnect();
  if (frame !== undefined) cancelAnimationFrame(frame);
  controls?.dispose();
  const geometries = new Set(), materials = new Set(), textures = new Set();
  model?.traverse((node) => {
    if (node.geometry) geometries.add(node.geometry);
    for (const material of node.material ? [node.material].flat() : []) {
      materials.add(material);
      for (const value of Object.values(material)) if (value?.isTexture) textures.add(value);
    }
  });
  for (const value of [...textures, ...materials, ...geometries]) value.dispose();
  renderer?.dispose();
};

document.querySelector("#reset").addEventListener("click", reset);
wireframe.addEventListener("click", () => setWireframe(wireframe.getAttribute("aria-pressed") !== "true"));
canvas.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key.toLowerCase() === "r") reset();
  else if (event.key.toLowerCase() === "w") setWireframe(wireframe.getAttribute("aria-pressed") !== "true");
  else if (["+", "=", "-"].includes(event.key)) {
    if (camera && controls) camera.position.sub(controls.target)
      .multiplyScalar(event.key === "-" ? 1.15 : 1 / 1.15).add(controls.target);
    controls?.update();
  } else return;
  event.preventDefault();
});
canvas.addEventListener("webglcontextlost", (event) => {
  if (!disposed) report("error", { message: "The 3D renderer stopped. Reload the file to try again.", contextReason: event.statusMessage });
});
const resizeObserver = new ResizeObserver(resize);
resizeObserver.observe(canvas);
