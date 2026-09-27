// Blog figures — hand-rolled components for the MDX posts.
// Styles live in template.html under /* Figures */; class names are
// semantic (dt-*, pc-*, sg-*, flow-*) and stable.

import { createElement as h } from "react";

const fmt = (n) =>
  typeof n === "number" ? (n >= 1000 ? n.toLocaleString("en-US") : String(n)) : n;

/* ------------------------------------------------------------------ */
/* DataTable — bordered table that fills its column and scrolls on     */
/* narrow screens.                                                     */
/* ------------------------------------------------------------------ */
export function DataTable({ title, columns, rows, align = [], footer }) {
  const alignFor = (i) => align[i] ?? "left";
  return h(
    "figure",
    { className: "fig dt" },
    title && h("figcaption", { className: "fig-title" }, title),
    h(
      "div",
      { className: "dt-scroll" },
      h(
        "table",
        null,
        h(
          "thead",
          null,
          h(
            "tr",
            null,
            columns.map((c, i) =>
              h("th", { key: i, style: { textAlign: alignFor(i) } }, c)
            )
          )
        ),
        h(
          "tbody",
          null,
          rows.map((r, i) =>
            h(
              "tr",
              { key: i },
              r.map((c, j) =>
                h("td", { key: j, style: { textAlign: alignFor(j) } }, c)
              )
            )
          )
        ),
        footer &&
          h(
            "tfoot",
            null,
            h(
              "tr",
              null,
              footer.map((c, i) =>
                h("td", { key: i, style: { textAlign: alignFor(i) } }, c)
              )
            )
          )
      )
    )
  );
}

/* ------------------------------------------------------------------ */
/* PerfChart — horizontal bar comparison. Each row gets one bar per    */
/* series value; bars normalize per-row ("row") or globally ("global") */
/* so a 0.3 ms ping and a 9 s df can share the figure. A ratio chip    */
/* marks the delta when one side wins by ≥1.5x.                        */
/* ------------------------------------------------------------------ */
export function PerfChart({ title, unit = "ms", columns, rows, scale = "row" }) {
  const globalMax = Math.max(...rows.flatMap((r) => r.values));
  return h(
    "figure",
    { className: "fig pc" },
    title &&
      h(
        "figcaption",
        { className: "fig-title pc-head" },
        h("span", null, title),
        h(
          "span",
          { className: "pc-legend" },
          columns.map((c, i) =>
            h(
              "span",
              { key: i, className: "pc-key" },
              h("i", { className: `pc-swatch pc-s${i}` }),
              c
            )
          )
        )
      ),
    h(
      "div",
      { className: "pc-rows" },
      rows.map(({ label, values, note }, ri) => {
        const rowMax = scale === "global" ? globalMax : Math.max(...values);
        const winner =
          values[0] <= values[1]
            ? { w: 0, ratio: values[1] / values[0] }
            : { w: 1, ratio: values[0] / values[1] };
        return h(
          "div",
          { className: "pc-row", key: ri },
          h("span", { className: "pc-label" }, label),
          h(
            "div",
            { className: "pc-bars" },
            values.map((v, vi) =>
              h(
                "div",
                { className: `pc-track`, key: vi },
                h("div", {
                  className: `pc-bar pc-s${vi}`,
                  style: { width: `${Math.max((v / rowMax) * 100, 2)}%` },
                })
              )
            )
          ),
          h(
            "div",
            { className: "pc-vals" },
            values.map((v, vi) =>
              h(
                "span",
                { className: `pc-val ${vi === winner.w ? "pc-win" : ""}`, key: vi },
                fmt(v),
                ` ${unit}`
              )
            )
          ),
          h(
            "span",
            { className: "pc-ratio" },
            winner.ratio >= 1.5
              ? `${winner.ratio >= 10 ? Math.round(winner.ratio) : winner.ratio.toFixed(1)}x`
              : note ?? ""
          )
        );
      })
    )
  );
}

/* ------------------------------------------------------------------ */
/* StatGrid — headline numbers.                                        */
/* ------------------------------------------------------------------ */
export function StatGrid({ title, items }) {
  return h(
    "figure",
    { className: "fig sg" },
    title && h("figcaption", { className: "fig-title" }, title),
    h(
      "div",
      { className: "sg-grid" },
      items.map(({ value, label }, i) =>
        h(
          "div",
          { className: "sg-item", key: i },
          h("span", { className: "sg-value" }, value),
          h("span", { className: "sg-label" }, label)
        )
      )
    )
  );
}

/* ------------------------------------------------------------------ */
/* Flow — lanes of steps joined by arrows. accent marks the hot node.  */
/* ------------------------------------------------------------------ */
export function Flow({ title, lanes }) {
  return h(
    "figure",
    { className: "fig flow" },
    title && h("figcaption", { className: "fig-title" }, title),
    h(
      "div",
      { className: "flow-lanes" },
      lanes.map(({ steps, accent }, i) =>
        h(
          "div",
          { className: "flow-lane", key: i },
          steps.map((s, j) =>
            h(
              "span",
              { className: "flow-seg", key: j },
              h("span", { className: `flow-node${j === accent ? " accent" : ""}` }, s),
              j < steps.length - 1 && h("span", { className: "flow-arrow" }, "→")
            )
          )
        )
      )
    )
  );
}

/* ------------------------------------------------------------------ */
/* Callout — title + markdown body, left accent bar.                   */
/* ------------------------------------------------------------------ */
export function Callout({ title = "note", tone = "note", children }) {
  return h(
    "aside",
    { className: `callout callout-${tone}` },
    h("span", { className: "callout-title" }, `[ ${title} ]`),
    h("div", { className: "callout-body" }, children)
  );
}
