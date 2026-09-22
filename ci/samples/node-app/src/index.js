import pc from "picocolors";

export function greet(name = "world") {
  return pc.green(`hello, ${name}`);
}

if (process.argv[1] === new URL(import.meta.url).pathname) {
  console.log(greet(process.argv[2]));
}
