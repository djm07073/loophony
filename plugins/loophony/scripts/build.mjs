import { build } from "esbuild";

await build({
  bundle: true,
  platform: "node",
  target: "node22",
  format: "esm",
  minify: true,
  packages: "bundle",
  logLevel: "info",
  entryPoints: ["src/mcp-server.ts"],
  outfile: "dist/mcp-server.mjs",
});
