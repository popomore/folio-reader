import { strToU8, zipSync } from "three/addons/libs/fflate.module.js";

const vertices = [[0, 0, 0], [20, 0, 0], [20, 20, 0], [0, 20, 0], [0, 0, 20], [20, 0, 20], [20, 20, 20], [0, 20, 20]];
const faces = [[0, 2, 1], [0, 3, 2], [4, 5, 6], [4, 6, 7], [0, 1, 5], [0, 5, 4], [3, 7, 6], [3, 6, 2], [0, 4, 7], [0, 7, 3], [1, 2, 6], [1, 6, 5]];
export const coreNamespace = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02";
export const productionNamespace = "http://schemas.microsoft.com/3dmanufacturing/production/2015/06";
export const modelXML = (resources, build, unit = "millimeter") => `<model xmlns="${coreNamespace}" xmlns:p="${productionNamespace}" unit="${unit}"><resources>${resources}</resources><build>${build}</build></model>`;
export const cubeXML = (color = "#e64b3c") => `<basematerials id="2"><base name="Fixture" displaycolor="${color}"/></basematerials><object id="1" type="model" pid="2" pindex="0"><mesh><vertices>${vertices.map(([x, y, z]) => `<vertex x="${x}" y="${y}" z="${z}"/>`).join("")}</vertices><triangles>${faces.map(([v1, v2, v3]) => `<triangle v1="${v1}" v2="${v2}" v3="${v3}"/>`).join("")}</triangles></mesh></object>`;

export function threeMF(parts, root = "/3D/3dmodel.model") {
  return zipSync(Object.fromEntries(Object.entries({
    "[Content_Types].xml": '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>',
    "_rels/.rels": `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="model" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel" Target="${root}"/></Relationships>`,
    ...parts,
  }).map(([name, text]) => [name, strToU8(text)])));
}

export function modelFixtures() {
  const ascii = `solid cube\n${faces.map((face) => `facet normal 0 0 0\nouter loop\n${face.map((i) => `vertex ${vertices[i].join(" ")}`).join("\n")}\nendloop\nendfacet`).join("\n")}\nendsolid cube\n`;
  const binarySTL = new Uint8Array(84 + faces.length * 50);
  const view = new DataView(binarySTL.buffer);
  view.setUint32(80, faces.length, true);
  faces.forEach((face, index) => face.forEach((vertex, corner) => vertices[vertex].forEach((value, axis) =>
    view.setFloat32(84 + index * 50 + 12 + corner * 12 + axis * 4, value, true))));
  const obj = `${vertices.map((v) => `v ${v.join(" ")}`).join("\n")}\n${faces.map((f) => `f ${f.map((i) => i + 1).join(" ")}`).join("\n")}\n`;
  const ply = `ply\nformat ascii 1.0\nelement vertex 8\nproperty float x\nproperty float y\nproperty float z\nelement face 12\nproperty list uchar int vertex_indices\nend_header\n${vertices.map((v) => v.join(" ")).join("\n")}\n${faces.map((f) => `3 ${f.join(" ")}`).join("\n")}\n`;
  const positions = new Float32Array(vertices.flat());
  const indices = new Uint16Array(faces.flat());
  const bin = new Uint8Array(positions.byteLength + indices.byteLength);
  bin.set(new Uint8Array(positions.buffer));
  bin.set(new Uint8Array(indices.buffer), positions.byteLength);
  const gltf = {
    asset: { version: "2.0" }, scene: 0, scenes: [{ nodes: [0] }], nodes: [{ mesh: 0 }],
    meshes: [{ primitives: [{ attributes: { POSITION: 0 }, indices: 1 }] }],
    buffers: [{ byteLength: bin.length }],
    bufferViews: [{ buffer: 0, byteOffset: 0, byteLength: positions.byteLength }, { buffer: 0, byteOffset: positions.byteLength, byteLength: indices.byteLength }],
    accessors: [{ bufferView: 0, componentType: 5126, count: 8, type: "VEC3", min: [0, 0, 0], max: [20, 20, 20] },
      { bufferView: 1, componentType: 5123, count: 36, type: "SCALAR" }],
  };
  const json = strToU8(JSON.stringify(gltf));
  const jsonLength = Math.ceil(json.length / 4) * 4;
  const glb = new Uint8Array(12 + 8 + jsonLength + 8 + bin.length);
  const glbView = new DataView(glb.buffer);
  glbView.setUint32(0, 0x46546c67, true);
  glbView.setUint32(4, 2, true);
  glbView.setUint32(8, glb.length, true);
  glbView.setUint32(12, jsonLength, true);
  glbView.setUint32(16, 0x4e4f534a, true);
  glb.fill(0x20, 20, 20 + jsonLength);
  glb.set(json, 20);
  glbView.setUint32(20 + jsonLength, bin.length, true);
  glbView.setUint32(24 + jsonLength, 0x004e4942, true);
  glb.set(bin, 28 + jsonLength);
  const assembly = modelXML('<object id="1"><components><component objectid="1" p:path="/3D/Objects/red.model"/><component objectid="1" p:path="/3D/Objects/green.model" transform="1 0 0 0 1 0 0 0 1 40 0 0"/></components></object>', '<item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 10 0"/>');
  const shear = modelXML(cubeXML() + '<object id="3"><components><component objectid="1" transform="1 0 0 1 1 0 0 0 1 0 0 0"/></components></object>',
    '<item objectid="3" transform="1 0 0 0 1 0 1 0 1 0 0 0"/>');
  const files = [
    ["cube-ascii.stl", strToU8(ascii), 1, 12], ["cube-binary.STL", binarySTL, 1, 12],
    ["cube.obj", strToU8(obj), 1, 12], ["cube.ply", strToU8(ply), 1, 12],
    ["cube.glb", glb, 1, 12],
    ["cube.gltf", strToU8(JSON.stringify({ ...gltf, buffers: [{ byteLength: bin.length, uri: "cube.bin" }] })), 1, 12],
    ["cube.bin", bin],
    ["assembly.3mf", threeMF({ "3D/3dmodel.model": assembly,
      "3D/Objects/red.model": modelXML(cubeXML(), ""),
      "3D/Objects/green.model": modelXML(cubeXML("#2aa66c"), ""),
      "Metadata/plate_1.gcode": "G1 X10 Y10\n", "Metadata/project_settings.config": '{"printer_model":"fixture"}' }), 2, 24],
    ["inch.3mf", threeMF({ "3D/3dmodel.model": modelXML(cubeXML(), '<item objectid="1"/>', "inch") }), 1, 12],
    ["shear.3mf", threeMF({ "3D/3dmodel.model": shear }), 1, 12],
    ["item-path.3mf", threeMF({ "3D/3dmodel.model": modelXML("", '<item p:path="/3D/Objects/part.model" objectid="1"/>'),
      "3D/Objects/part.model": modelXML(cubeXML(), "") }), 1, 12],
    ["sliced.gcode.3mf", threeMF({ "Metadata/plate_1.gcode": "G1 X10 Y10" }), 0, 0, "no model geometry"],
    ["broken.stl", strToU8("not a mesh"), 0, 0, "invalid"],
    ["cycle.3mf", threeMF({ "3D/3dmodel.model": modelXML('<object id="1"><components><component objectid="1"/></components></object>', '<item objectid="1"/>') }), 0, 0, "cycle"],
    ["remote.gltf", strToU8(JSON.stringify({ ...gltf, buffers: [{ byteLength: bin.length, uri: "https://example.invalid/model.bin" }] })), 0, 0, "own folder"],
    ["escape.gltf", strToU8(JSON.stringify({ ...gltf, buffers: [{ byteLength: bin.length, uri: "../outside.bin" }] })), 0, 0, "own folder"],
  ];
  return files.map(([name, data, meshes, triangles, error]) => ({ name, data, meshes, triangles, error }));
}
