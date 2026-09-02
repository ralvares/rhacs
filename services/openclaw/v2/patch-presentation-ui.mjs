import { readdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// OpenClaw 2026.7.1 keeps these preferences in each browser profile and does
// not accept the newer ui.prefs gateway configuration. This demo image uses a
// fail-closed, version-specific presentation default so a fresh browser cannot
// expose model thinking or tool cards to the audience. Tool execution and
// results remain in the gateway session and RHACS telemetry.
const assets = process.env.OPENCLAW_CONTROL_UI_ASSETS ?? "/opt/openclaw/dist/control-ui/assets";
const bundle = readdirSync(assets).find((name) => name.startsWith("index-") && name.endsWith(".js"));

if (!bundle) {
  throw new Error("OpenClaw Control UI bundle was not found");
}

const path = join(assets, bundle);
const source = readFileSync(path, "utf8");
const preferenceMerge = /chatShowThinking:typeof ([A-Za-z_$][\w$]*)\.chatShowThinking==`boolean`\?\1\.chatShowThinking:([A-Za-z_$][\w$]*)\.chatShowThinking,chatShowToolCalls:typeof \1\.chatShowToolCalls==`boolean`\?\1\.chatShowToolCalls:\2\.chatShowToolCalls/;
const matches = source.match(new RegExp(preferenceMerge.source, "g")) ?? [];

if (matches.length !== 1) {
  throw new Error(`Expected one OpenClaw presentation preference merge, found ${matches.length}`);
}

const patched = source.replace(preferenceMerge, "chatShowThinking:!1,chatShowToolCalls:!1");
writeFileSync(path, patched);

// Give the modified entry bundle a new URL so an already-used demo browser
// cannot reuse OpenClaw's long-lived immutable cache entry.
const audienceBundle = `audience-${bundle}`;
const audiencePath = join(assets, audienceBundle);
const indexPath = "/opt/openclaw/dist/control-ui/index.html";
const index = readFileSync(indexPath, "utf8");
const references = index.split(bundle).length - 1;
if (references !== 1) {
  throw new Error(`Expected one ${bundle} reference in Control UI index, found ${references}`);
}
let moduleReferences = 0;
for (const name of readdirSync(assets)) {
  if (name === bundle || !name.endsWith(".js")) continue;
  const modulePath = join(assets, name);
  const moduleSource = readFileSync(modulePath, "utf8");
  const count = moduleSource.split(bundle).length - 1;
  if (count === 0) continue;
  moduleReferences += count;
  writeFileSync(modulePath, moduleSource.split(bundle).join(audienceBundle));
}
if (moduleReferences === 0) {
  throw new Error(`No lazy-loaded modules referenced ${bundle}`);
}
renameSync(path, audiencePath);
writeFileSync(indexPath, index.replace(bundle, audienceBundle));
console.log(`OpenClaw audience mode applied to ${audienceBundle}; rewrote ${moduleReferences} module references`);
