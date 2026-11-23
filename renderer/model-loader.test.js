import test from "node:test";
import assert from "node:assert/strict";
import { Box3, BufferGeometry, Float32BufferAttribute, InstancedMesh, MeshStandardMaterial, Vector3 } from "three";
import { inspectModel, localResourceURL, parseModel } from "./model-loader.js";
import { modelFixtures } from "./model-fixtures.js";

const base = "folio-model://preview/files/";
for (const fixture of modelFixtures().filter((file) => /\.(stl|obj|ply)$/i.test(file.name) && file.meshes)) {
  test(`reads independent ${fixture.name} geometry`, async () => {
    const result = await parseModel(fixture.data.buffer, fixture.name, base);
    assert.equal(result.meshes, fixture.meshes);
    assert.equal(result.triangles, fixture.triangles);
    assert.deepEqual(new Box3().setFromObject(result.object).getSize(new Vector3()).toArray().map(Math.round), [20, 20, 20]);
    if (/\.stl$/i.test(fixture.name)) {
      assert.ok(result.object.geometry.getAttribute("normal").array.some((value) => value !== 0),
        "STL files with omitted normals must still have lit surfaces.");
    }
  });
}

test("blocks remote, parent and other-origin model resources", () => {
  for (const uri of ["https://example.com/a.bin", "../outside.bin", "file:///tmp/a.bin", "folio-model://other/files/a.bin"]) {
    assert.throws(() => localResourceURL(uri, base), /own folder/);
  }
  assert.equal(localResourceURL("textures/a.png", base), `${base}textures/a.png`);
  assert.equal(localResourceURL("data:application/octet-stream;base64,AA==", base), "data:application/octet-stream;base64,AA==");
});

test("rejects empty and malformed models", async () => {
  await assert.rejects(parseModel(new ArrayBuffer(0), "empty.stl", base), /empty/);
  await assert.rejects(parseModel(new TextEncoder().encode("not a mesh").buffer, "broken.obj", base), /no viewable/);
});

test("preserves PLY surfaces after long header comments", async () => {
  const fixture = modelFixtures().find((file) => file.name === "cube.ply");
  const source = new TextDecoder().decode(fixture.data).replace("element vertex", `comment ${"metadata ".repeat(10_000)}\nelement vertex`);
  const result = await parseModel(new TextEncoder().encode(source).buffer, "long-header.ply", base);
  assert.ok(result.object.isMesh);
  assert.equal(result.triangles, 12);
});

test("counts displayed instances and enforces their triangle budget", () => {
  const geometry = new BufferGeometry();
  geometry.setAttribute("position", new Float32BufferAttribute([0, 0, 0, 1, 0, 0, 0, 1, 0], 3));
  geometry.setIndex(Array.from({ length: 9000 }, (_, i) => i % 3));
  const instances = new InstancedMesh(geometry, new MeshStandardMaterial(), 1000);
  assert.throws(() => inspectModel(instances), /too complex/);
  instances.count = 3;
  assert.deepEqual(inspectModel(instances), { meshes: 3, triangles: 9000, vertices: 9 });
});
