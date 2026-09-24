/* eslint-disable @typescript-eslint/no-require-imports */

// Prism-based syntax highlighting, tokens mapped to the explorer palette via
// `.tok-*` classes in globals.css. Loaded eagerly (static export — no dynamic
// grammar fetching at runtime).

import Prism from "prismjs";
import "prismjs/components/prism-bash.js";
import "prismjs/components/prism-python.js";
import "prismjs/components/prism-go.js";
import "prismjs/components/prism-swift.js";
import "prismjs/components/prism-json.js";
import "prismjs/components/prism-yaml.js";

const ALIASES: Record<string, string> = {
  shell: "bash",
  sh: "bash",
  curl: "bash",
  js: "javascript",
  py: "python",
  yml: "yaml",
};

const escapeHTML = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// Prism token type → palette class (see globals.css). Longest-prefix wins.
const TOKEN_CLASSES: [string[], string][] = [
  [["comment", "prolog", "doctype", "cdata"], "tok-comment"],
  [["string", "char", "attr-value", "template-string"], "tok-string"],
  [["number", "boolean"], "tok-number"],
  [["keyword", "important", "rule", "boolean"], "tok-keyword"],
  [["function", "method", "function-variable"], "tok-function"],
  [["property", "attr-name", "key", "tag", "selector"], "tok-property"],
  [["operator", "url", "entity"], "tok-operator"],
  [["punctuation"], "tok-punct"],
  [["class-name", "builtin", "namespace", "constant", "symbol"], "tok-type"],
  [["regex", "variable", "parameter"], "tok-variable"],
  [["inserted"], "tok-string"],
  [["deleted"], "tok-deleted"],
];

function classFor(type: string): string {
  for (const [types, cls] of TOKEN_CLASSES) {
    if (types.some((t) => type === t || type.startsWith(t + "-") || type.startsWith(t + "_"))) {
      return cls;
    }
  }
  return "";
}

function renderToken(token: string | Prism.Token): string {
  if (typeof token === "string") return escapeHTML(token);
  const inner = Array.isArray(token.content)
    ? token.content.map(renderToken).join("")
    : renderToken(token.content as string | Prism.Token);
  const cls = classFor(token.type);
  return cls ? `<span class="${cls}">${inner}</span>` : inner;
}

/** Highlight `code` as `lang` → HTML string. Falls back to escaped text. */
export function highlight(code: string, lang?: string): string {
  const grammar = Prism.languages[ALIASES[lang ?? ""] ?? lang ?? ""];
  if (!grammar) return escapeHTML(code);
  return Prism.tokenize(code, grammar).map(renderToken).join("");
}
