import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { modelFixtures } from "../renderer/model-fixtures.js";

const output = process.argv[2];
if (!output) throw new Error("Provide a fixture output directory.");
await mkdir(output, { recursive: true });
const fixtures = modelFixtures();
for (const { name, data } of fixtures) await writeFile(resolve(output, name), data);
await writeFile(resolve(output, "manifest.json"), JSON.stringify(fixtures.filter((file) => file.meshes !== undefined)
  .map(({ name, meshes, triangles, error }) => ({ name, meshes, triangles, error: error ?? null })), null, 2));
