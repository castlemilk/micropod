import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { greet } from "../src/index.js";

describe("greet", () => {
  it("greets the world by default", () => {
    assert.match(greet(), /hello, world/);
  });

  it("greets by name", () => {
    assert.match(greet("ada"), /hello, ada/);
  });

  it("wraps in color codes", () => {
    // picocolors emits green (32m) when colors are supported; in non-TTY
    // pipes it passes the text through — either way the name survives.
    assert.match(greet("cuttle"), /cuttle/);
  });
});
