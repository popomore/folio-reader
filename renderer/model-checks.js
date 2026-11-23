import { Box3, Vector3 } from "three";
import { parseModel, parseThreeMF } from "./model-loader.js";
import { cubeXML, modelFixtures, modelXML, threeMF } from "./model-fixtures.js";

window.folioModelParserChecks = async () => {
  const require = (condition, message) => { if (!condition) throw new Error(message); };
  const assembly = modelFixtures().find((file) => file.name === "assembly.3mf");
  const { object } = parseThreeMF(assembly.data.buffer);
  const box = new Box3().setFromObject(object);
  require(box.min.toArray().join() === "0,10,0" && box.max.toArray().join() === "60,30,20", "3MF component and build transforms were not preserved.");
  const colors = [];
  object.traverse((node) => { if (node.isMesh) colors.push([...node.geometry.getAttribute("color").array.slice(0, 4)]); });
  require(colors.length === 2 && colors[0][0] > colors[0][1] && colors[1][1] > colors[1][0], "Cross-file resource IDs or base colors were mixed up.");
  const shearXML = modelXML(cubeXML() + '<object id="3"><components><component objectid="1" transform="1 0 0 1 1 0 0 0 1 0 0 0"/></components></object>',
    '<item objectid="3" transform="1 0 0 0 1 0 1 0 1 0 0 0"/>');
  const shear = parseThreeMF(threeMF({ "3D/3dmodel.model": shearXML }).buffer).object;
  shear.updateMatrixWorld(true);
  require(new Box3().setFromObject(shear).getSize(new Vector3()).toArray().join() === "60,20,20",
    "3MF component and build shear matrices must survive world-matrix updates.");
  const inches = modelFixtures().find((file) => file.name === "inch.3mf");
  const inchModel = parseThreeMF(inches.data.buffer).object;
  require(Math.abs(new Box3().setFromObject(inchModel).getSize(new Vector3()).x - 508) < 0.001, "3MF physical units were lost.");
  const badXML = threeMF({ "3D/3dmodel.model": "<model><resources></model>" });
  const invalidFace = threeMF({ "3D/3dmodel.model": modelXML(cubeXML().replace('v1="0"', 'v1="999"'), '<item objectid="1"/>') });
  const invalidTransform = threeMF({ "3D/3dmodel.model": modelXML(cubeXML(), '<item objectid="1" transform="1 2 NaN"/>') });
  const duplicate = threeMF({ "3D/3dmodel.model": modelXML(cubeXML() + cubeXML(), '<item objectid="1"/>') });
  const unsupported = threeMF({ "3D/3dmodel.model": modelXML(cubeXML(), '<item objectid="1"/>').replace("<model ", '<model xmlns:x="urn:unsupported" requiredextensions="x" ') });
  const oversized = threeMF({ "3D/3dmodel.model": modelXML(cubeXML(), '<item objectid="1"/>') });
  const zipView = new DataView(oversized.buffer);
  for (let i = 0; i + 46 < oversized.length; i++) {
    if (zipView.getUint32(i, true) === 0x02014b50) {
      const nameLength = zipView.getUint16(i + 28, true);
      const name = new TextDecoder().decode(oversized.slice(i + 46, i + 46 + nameLength));
      if (name.endsWith(".model")) { zipView.setUint32(i + 24, 129 * 1024 * 1024, true); break; }
    }
  }
  for (const [data, message] of [[badXML, "XML"], [invalidFace, "triangle"], [invalidTransform, "transform"], [duplicate, "duplicate"], [unsupported, "unsupported"], [oversized, "too large"]]) {
    let error;
    try { parseThreeMF(data.buffer); } catch (failure) { error = failure; }
    require(error?.message.includes(message), `Expected a 3MF ${message} error.`);
  }
  const points = new TextEncoder().encode("ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nend_header\n0 0 0\n1 2 3\n");
  const pointCloud = await parseModel(points.buffer, "points.ply", "folio-model://preview/files/");
  require(pointCloud.object.isPoints && pointCloud.triangles === 0, "PLY point clouds should not become triangle meshes.");
  const faceColors = new TextEncoder().encode("ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nelement face 1\nproperty list uchar int vertex_indices\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n0 0 0\n1 0 0\n0 1 0\n3 0 1 2 255 0 0\n");
  const coloredPLY = await parseModel(faceColors.buffer, "face-colors.ply", "folio-model://preview/files/");
  require(coloredPLY.object.isMesh && coloredPLY.triangles === 1, "PLY face colors should remain a mesh after expanding indexed vertices.");
  return "Verified 3MF transforms, units, cross-file colors, invalid input and PLY points in WebKit.";
};
