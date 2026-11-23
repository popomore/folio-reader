import {
  BufferGeometry, Color, DoubleSide, Float32BufferAttribute, Group, LoadingManager,
  Matrix4, Mesh, MeshStandardMaterial, Points, PointsMaterial,
} from "three";
import { GLTFLoader } from "three/addons/loaders/GLTFLoader.js";
import { OBJLoader } from "three/addons/loaders/OBJLoader.js";
import { PLYLoader } from "three/addons/loaders/PLYLoader.js";
import { STLLoader } from "three/addons/loaders/STLLoader.js";
import { unzipSync } from "three/addons/libs/fflate.module.js";

export const MAX_MODEL_BYTES = 128 * 1024 * 1024;
const MAX_TRIANGLES = 2_000_000;
const MAX_VERTICES = 6_000_000;
const decoder = new TextDecoder();

export function localResourceURL(value, base) {
  const url = new URL(value, base);
  const origin = new URL(base);
  if (["data:", "blob:"].includes(url.protocol)) return url.href;
  if (url.protocol !== origin.protocol || url.host !== origin.host || !url.pathname.startsWith("/files/")) {
    throw new Error("Models can only load resources from their own folder.");
  }
  return url.href;
}

export async function parseModel(buffer, name, base) {
  if (!buffer.byteLength || buffer.byteLength > MAX_MODEL_BYTES) {
    throw new Error("This model is empty or exceeds the 128 MiB preview limit.");
  }
  const extension = name.split(".").at(-1).toLowerCase();
  const manager = new LoadingManager();
  manager.setURLModifier((url) => localResourceURL(url, base));
  let object;
  let note = "";
  let unit = "model units";
  switch (extension) {
    case "stl": {
      const geometry = new STLLoader().parse(buffer);
      geometry.computeVertexNormals();
      object = mesh(geometry);
      break;
    }
    case "obj":
      object = new OBJLoader(manager).parse(decoder.decode(buffer));
      note = "OBJ geometry and vertex colors. External MTL materials are not shown.";
      break;
    case "ply": {
      const geometry = new PLYLoader().parse(buffer);
      object = plyHasFaces(buffer) ? mesh(geometry) : new Points(geometry, new PointsMaterial({
        color: geometry.hasAttribute("color") ? 0xffffff : 0x6796ba,
        vertexColors: geometry.hasAttribute("color"), size: 2, sizeAttenuation: false,
      }));
      break;
    }
    case "gltf":
    case "glb":
      object = (await new GLTFLoader(manager).parseAsync(buffer, base)).scene;
      break;
    case "3mf":
      ({ object, note } = parseThreeMF(buffer));
      unit = "mm";
      break;
    default:
      throw new Error("This 3D format is not supported.");
  }
  const stats = inspectModel(object);
  if (["stl", "3mf"].includes(extension)) object.rotation.x = -Math.PI / 2;
  object.updateMatrixWorld(true);
  return { object, note, unit, ...stats };
}

function plyHasFaces(buffer) {
  const bytes = new Uint8Array(buffer);
  let start = 0, faces = false;
  for (let end = 0; end < bytes.length; end++) {
    if (bytes[end] !== 10 && bytes[end] !== 13) continue;
    const line = decoder.decode(bytes.subarray(start, end)).trim();
    if (line === "end_header") return faces;
    if (/^element\s+face\s+[1-9]\d*$/.test(line)) faces = true;
    start = end + 1;
  }
  throw new Error("The PLY header is incomplete.");
}

function mesh(geometry) {
  if (!geometry.hasAttribute("normal")) geometry.computeVertexNormals();
  const colored = geometry.hasAttribute("color");
  return new Mesh(geometry, new MeshStandardMaterial({
    color: colored ? 0xffffff : 0x6796ba, vertexColors: colored,
    roughness: 0.72, metalness: 0, side: DoubleSide,
  }));
}

export function inspectModel(object) {
  let meshes = 0, triangles = 0, vertices = 0;
  object.traverse((node) => {
    if (!node.isMesh && !node.isPoints && !node.isLine) return;
    const instances = node.isInstancedMesh ? node.count : 1;
    if (!Number.isInteger(instances) || instances < 0) throw new Error("This model contains an invalid instance count.");
    meshes += instances;
    if (meshes > 10_000) throw new Error("This model has too many parts to preview.");
    const geometry = node.geometry;
    const positions = geometry.getAttribute("position");
    if (!positions) throw new Error("This model has no vertex positions.");
    vertices += positions.count * instances;
    if (node.isMesh) triangles += (geometry.index?.count ?? positions.count) / 3 * instances;
    if (node.isMesh && (geometry.index?.count ?? positions.count) % 3 !== 0) {
      throw new Error("This model contains an incomplete triangle.");
    }
    if (vertices > MAX_VERTICES || triangles > MAX_TRIANGLES) {
      throw new Error("This model is too complex to preview (maximum 2 million triangles).");
    }
    for (let i = 0; i < positions.count; i++) {
      if (![positions.getX(i), positions.getY(i), positions.getZ(i)].every(Number.isFinite)) {
        throw new Error("This model contains invalid vertex positions.");
      }
    }
    if (geometry.index) {
      for (const index of geometry.index.array) {
        if (!Number.isInteger(index) || index < 0 || index >= positions.count) throw new Error("This model contains an invalid face.");
      }
    }
    for (const value of node.matrix.elements) {
      if (!Number.isFinite(value)) throw new Error("This model contains an invalid transform.");
    }
  });
  if (!vertices) throw new Error("This file contains no viewable model geometry.");
  return { meshes, triangles: Math.floor(triangles), vertices };
}

function xml(bytes) {
  const source = decoder.decode(bytes);
  if (/<!DOCTYPE|<!ENTITY/i.test(source)) throw new Error("3MF documents cannot contain external entities.");
  const document = new DOMParser().parseFromString(source, "application/xml");
  if (document.getElementsByTagName("parsererror").length) throw new Error("The 3MF model XML is invalid.");
  return document;
}

const children = (node, name) => [...(node?.children ?? [])].filter((child) => child.localName === name);
const child = (node, name) => children(node, name)[0];

function partPath(target, source = "") {
  if (!target || /^[a-z][a-z\d+.-]*:/i.test(target) || target.startsWith("//") || target.includes("\\")) {
    throw new Error("The 3MF archive contains an invalid part path.");
  }
  const path = new URL(target, `https://archive.invalid/${source}`).pathname;
  return decodeURIComponent(path.slice(1));
}

export function parseThreeMF(buffer) {
  let total = 0, count = 0;
  const files = unzipSync(new Uint8Array(buffer), { filter(entry) {
    if (++count > 4096) throw new Error("This 3MF archive has too many files.");
    if (!/\.(model|rels)$/i.test(entry.name)) return false;
    total += entry.originalSize;
    if (entry.originalSize > MAX_MODEL_BYTES || total > 256 * 1024 * 1024) {
      throw new Error("This 3MF archive is too large to preview.");
    }
    return true;
  } });
  const relationships = files["_rels/.rels"] && xml(files["_rels/.rels"]);
  const relationship = relationships && [...relationships.getElementsByTagNameNS("*", "Relationship")]
    .find((node) => node.getAttribute("Type")?.endsWith("/3dmodel"));
  if (relationship?.getAttribute("TargetMode") === "External") throw new Error("External 3MF models are not supported.");
  const rootPath = relationship ? partPath(relationship.getAttribute("Target")) : "3D/3dmodel.model";
  if (!files[rootPath]) {
    throw new Error("This 3MF contains no model geometry. Sliced G-code alone cannot be shown as a 3D model.");
  }
  const models = new Map(), cache = new Map(), active = new Set();
  let sourceTriangles = 0, instances = 0, hasTextures = false;
  function model(path) {
    if (models.has(path)) return models.get(path);
    if (!files[path]) throw new Error("A part referenced by this 3MF is missing.");
    const node = xml(files[path]).documentElement;
    if (node.localName !== "model") throw new Error("The 3MF model part is invalid.");
    for (const prefix of (node.getAttribute("requiredextensions") || "").split(/\s+/).filter(Boolean)) {
      const namespace = node.lookupNamespaceURI(prefix);
      if (!["http://schemas.microsoft.com/3dmanufacturing/production/2015/06",
        "http://schemas.microsoft.com/3dmanufacturing/material/2015/02"].includes(namespace)) {
        throw new Error("This 3MF requires an unsupported geometry extension.");
      }
    }
    const scales = { micron: 0.001, millimeter: 1, centimeter: 10, inch: 25.4, foot: 304.8, meter: 1000 };
    const scale = scales[node.getAttribute("unit") || "millimeter"];
    if (!scale) throw new Error("The 3MF model uses an unknown unit.");
    const resources = new Map();
    for (const resource of child(node, "resources")?.children ?? []) {
      const id = resource.getAttribute("id");
      if (id) {
        if (resources.has(id)) throw new Error("The 3MF model contains duplicate resource IDs.");
        resources.set(id, resource);
      }
      hasTextures ||= resource.localName === "texture2d";
    }
    const result = { node, resources, scale, colors: new Map() };
    models.set(path, result);
    return result;
  }
  function transform(node, scale) {
    const value = node.getAttribute("transform");
    if (!value) return new Matrix4();
    const t = value.trim().split(/\s+/).map(Number);
    if (t.length !== 12 || !t.every(Number.isFinite)) throw new Error("The 3MF model contains an invalid transform.");
    return new Matrix4().set(t[0], t[3], t[6], t[9] * scale,
      t[1], t[4], t[7], t[10] * scale, t[2], t[5], t[8], t[11] * scale, 0, 0, 0, 1);
  }
  function property(data, pid, index) {
    const key = `${pid}/${index}`;
    if (data.colors.has(key)) return data.colors.get(key);
    const resource = data.resources.get(pid);
    if (!resource || !["basematerials", "colorgroup"].includes(resource.localName)) return [0.14, 0.3, 0.49, 1];
    const base = resource.children[Number(index ?? 0)];
    const value = base?.getAttribute("displaycolor") ?? base?.getAttribute("color");
    if (!/^#[\da-f]{6}([\da-f]{2})?$/i.test(value ?? "")) throw new Error("The 3MF model contains an invalid color.");
    const color = new Color(value.slice(0, 7));
    const result = [color.r, color.g, color.b, value.length === 9 ? parseInt(value.slice(7), 16) / 255 : 1];
    data.colors.set(key, result);
    return result;
  }
  function build(path, id, depth = 0) {
    const key = `${path}#${id}`;
    if (depth > 64 || active.has(key)) throw new Error("The 3MF assembly contains a cycle or is too deeply nested.");
    if (++instances > 10_000) throw new Error("This 3MF has too many component instances.");
    if (cache.has(key)) return cache.get(key).clone(true);
    active.add(key);
    const data = model(path);
    const source = data.resources.get(id);
    if (source?.localName !== "object") throw new Error("The 3MF assembly references a missing object.");
    const group = new Group();
    let assemblyNodes = 1;
    group.name = source.getAttribute("name") || `Part ${id}`;
    const sourceMesh = child(source, "mesh");
    if (sourceMesh) {
      const vertices = children(child(sourceMesh, "vertices"), "vertex").map((vertex) =>
        ["x", "y", "z"].map((axis) => vertex.hasAttribute(axis) ? Number(vertex.getAttribute(axis)) * data.scale : NaN));
      if (vertices.length > MAX_VERTICES || vertices.some((v) => !v.every(Number.isFinite))) {
        throw new Error("The 3MF model contains invalid or too many vertices.");
      }
      const faces = children(child(sourceMesh, "triangles"), "triangle");
      sourceTriangles += faces.length;
      if (sourceTriangles > MAX_TRIANGLES) throw new Error("This 3MF has too many triangles to preview.");
      const positions = new Float32Array(faces.length * 9);
      const colors = new Float32Array(faces.length * 12);
      let transparent = false;
      faces.forEach((face, faceIndex) => {
        const pid = face.getAttribute("pid") ?? source.getAttribute("pid");
        const p1 = face.getAttribute("p1") ?? source.getAttribute("pindex") ?? "0";
        for (let corner = 0; corner < 3; corner++) {
          const value = face.getAttribute(`v${corner + 1}`);
          const index = value === null ? NaN : Number(value);
          if (!Number.isInteger(index) || index < 0 || !vertices[index]) throw new Error("The 3MF model contains an invalid triangle.");
          positions.set(vertices[index], faceIndex * 9 + corner * 3);
          const color = property(data, pid, face.getAttribute(`p${corner + 1}`) ?? p1);
          colors.set(color, faceIndex * 12 + corner * 4);
          transparent ||= color[3] < 1;
        }
      });
      const geometry = new BufferGeometry();
      geometry.setAttribute("position", new Float32BufferAttribute(positions, 3));
      geometry.setAttribute("color", new Float32BufferAttribute(colors, 4));
      const object = mesh(geometry);
      object.material.transparent = transparent;
      group.add(object);
    } else {
      for (const component of children(child(source, "components"), "component")) {
        const target = [...component.attributes].find((attr) => attr.localName === "path")?.value;
        const part = target ? partPath(target, path) : path;
        const object = build(part, component.getAttribute("objectid"), depth + 1);
        assemblyNodes += object.userData.assemblyNodes;
        if (assemblyNodes > 10_000) throw new Error("This 3MF assembly has too many instances to preview.");
        object.applyMatrix4(transform(component, data.scale));
        object.matrixAutoUpdate = false;
        group.add(object);
      }
    }
    active.delete(key);
    group.userData.assemblyNodes = assemblyNodes;
    cache.set(key, group);
    return group.clone(true);
  }
  const root = model(rootPath);
  const object = new Group();
  let assemblyNodes = 0;
  for (const item of children(child(root.node, "build"), "item")) {
    const target = [...item.attributes].find((attr) => attr.localName === "path")?.value;
    const instance = build(target ? partPath(target, rootPath) : rootPath, item.getAttribute("objectid"));
    assemblyNodes += instance.userData.assemblyNodes;
    if (assemblyNodes > 10_000) throw new Error("This 3MF build has too many instances to preview.");
    instance.applyMatrix4(transform(item, root.scale));
    instance.matrixAutoUpdate = false;
    object.add(instance);
  }
  return { object, note: hasTextures
    ? "3MF geometry and base colors. Texture maps, slicer paint and printer settings are not shown."
    : "3MF geometry and base colors. Slicer paint and printer settings are not shown." };
}
