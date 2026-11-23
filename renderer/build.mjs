import { build } from "esbuild";
import { fileURLToPath } from "node:url";

const output = process.argv[2];
if (!output) throw new Error("Provide the resource output directory.");
await build({
  entryPoints: [fileURLToPath(new URL("./reader.js", import.meta.url))],
  bundle: true,
  minify: true,
  outfile: `${output}/reader.js`,
  target: "safari17",
  legalComments: "linked",
  define: { "process.env.NODE_ENV": '"production"' },
});
await build({
  entryPoints: [fileURLToPath(new URL("./model-viewer.js", import.meta.url))],
  bundle: true,
  minify: true,
  outfile: `${output}/model-viewer.js`,
  target: "safari17",
  legalComments: "linked",
});
