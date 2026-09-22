import { nanoid } from "nanoid";

// Deliberately different dependency set (nanoid) from node-app/b: its
// `npm ci` layer actually fetches, proving the matrix can tell shared
// cache hits from genuine misses.
export function token() {
  return `tok-${nanoid(8)}`;
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  console.log(token());
}
