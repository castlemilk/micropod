import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { token } from "../src/index.js";

describe("token", () => {
  it("mints prefixed tokens", () => {
    assert.match(token(), /^tok-[A-Za-z0-9_-]{8}$/);
  });
});
