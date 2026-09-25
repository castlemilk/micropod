// Build blog posts: blog/posts/*.mdx -> landing/blog/<slug>/index.html
// MDX is the source of truth; output is static HTML in the landing chrome.
// Figures are hand-rolled components in blog-components.jsx, bundled by
// esbuild and server-rendered — no client JS.

import { compile, run } from "@mdx-js/mdx";
import remarkGfm from "remark-gfm";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import * as runtime from "react/jsx-runtime";
import * as esbuild from "esbuild";
import { readdirSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { pathToFileURL } from "url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "../..");
const POSTS_DIR = join(ROOT, "blog/posts");
const OUT_DIR = join(ROOT, "landing/blog");
const BASE = "/micropod/blog";

// Minimal frontmatter parser (--- yaml subset: key: value, [arrays]).
function frontmatter(src) {
  const m = src.match(/^---\n([\s\S]*?)\n---\n/);
  const meta = {};
  if (!m) return { meta, body: src };
  for (const line of m[1].split("\n")) {
    const kv = line.match(/^(\w+):\s*(.*)$/);
    if (!kv) continue;
    let v = kv[2].trim();
    if (v.startsWith("[") && v.endsWith("]"))
      v = v.slice(1, -1).split(",").map((s) => s.trim().replace(/^['"]|['"]$/g, ""));
    else v = v.replace(/^['"]|['"]$/g, "");
    meta[kv[1]] = v;
  }
  return { meta, body: src.slice(m[0].length) };
}

// Bundle the figure components for Node SSR.
const bundleOut = join(HERE, "node_modules/.cache/blog-components.mjs");
await esbuild.build({
  entryPoints: [join(HERE, "blog-components.jsx")],
  outfile: bundleOut,
  bundle: true,
  format: "esm",
  platform: "node",
  jsx: "automatic",
  external: ["react", "react-dom"],
  logLevel: "warning",
});

const components = await import(pathToFileURL(bundleOut).href);

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

const template = readFileSync(join(HERE, "template.html"), "utf8");

function render(meta, bodyHtml, slug) {
  const tags = (meta.tags ?? []).map((t) => `<span class="tag">${esc(t)}</span>`).join("");
  return template
    .replaceAll("{{TITLE}}", esc(meta.title))
    .replaceAll("{{DESCRIPTION}}", esc(meta.description))
    .replaceAll("{{CANONICAL}}", `${BASE}/${slug}/`)
    .replaceAll("{{DATE}}", esc(meta.date))
    .replaceAll("{{READING}}", esc(meta.reading ?? ""))
    .replaceAll("{{TAGS}}", tags)
    .replaceAll("{{STANDFIRST}}", esc(meta.standfirst))
    .replaceAll("{{GRAPH_CSS}}", "")
    .replaceAll("{{BODY}}", bodyHtml);
}

async function buildPost(file) {
  const src = readFileSync(join(POSTS_DIR, file), "utf8");
  const { meta, body } = frontmatter(src);
  const slug = file.replace(/\.mdx$/, "");
  const compiled = await compile(body, {
    outputFormat: "function-body",
    remarkPlugins: [remarkGfm],
  });
  const { default: Content } = await run(compiled, {
    ...runtime,
    useDynamicImport: false,
  });
  const bodyHtml = renderToStaticMarkup(
    createElement(Content, { components }),
  );
  const dir = join(OUT_DIR, slug);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "index.html"), render(meta, bodyHtml, slug));
  console.log(`built ${BASE}/${slug}/`);
  return { slug, ...meta };
}

rmSync(OUT_DIR, { recursive: true, force: true });
mkdirSync(OUT_DIR, { recursive: true });
const files = readdirSync(POSTS_DIR).filter((f) => f.endsWith(".mdx"));
const posts = [];
for (const f of files) posts.push(await buildPost(f));
posts.sort((a, b) => (a.date < b.date ? 1 : -1));

// Index page
const cards = posts
  .map(
    (p) => `        <a class="post-card" href="${BASE}/${p.slug}/">
          <p class="post-date">${esc(p.date)}</p>
          <h2>${esc(p.title)}</h2>
          <p>${esc(p.standfirst)}</p>
          <div class="post-tags">${(p.tags ?? []).map((t) => `<span class="tag">${esc(t)}</span>`).join("")}</div>
        </a>`,
  )
  .join("\n");
writeFileSync(
  join(OUT_DIR, "index.html"),
  template
    .replaceAll("{{TITLE}}", "Blog")
    .replaceAll("{{DESCRIPTION}}", "Engineering notes on Micropod — benchmarks, internals, and the odd honest regression.")
    .replaceAll("{{CANONICAL}}", `${BASE}/`)
    .replaceAll("{{DATE}}", "")
    .replaceAll("{{READING}}", "")
    .replaceAll("{{TAGS}}", "")
    .replaceAll("{{STANDFIRST}}", "")
    .replaceAll("{{GRAPH_CSS}}", "")
    .replaceAll(
      "{{BODY}}",
      `<div class="post-list">\n${cards}\n      </div>`,
    ),
);
console.log(`built ${BASE}/ (${posts.length} posts)`);
