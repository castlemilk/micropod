import pc from "picocolors";

// Same dependency set as node-app (picocolors), different code.
export function shout(name = "world") {
  return pc.red(`hey, ${name}!`);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  console.log(shout(process.argv[2]));
}
