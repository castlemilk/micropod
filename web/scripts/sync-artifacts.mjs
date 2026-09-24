// Copies the generated API artifacts (landing/api/) into public/api/ so the
// explorer can link to the raw specs and proto reference during `next dev`
// and they are bundled into the static export. Run via predev/prebuild.
import { cpSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "..", "landing", "api");
// Served at /micropod/api/specs/... after export.
const dst = join(root, "public", "specs");

mkdirSync(dst, { recursive: true });
cpSync(src, dst, { recursive: true });
console.log(`synced ${src} -> ${dst}`);
