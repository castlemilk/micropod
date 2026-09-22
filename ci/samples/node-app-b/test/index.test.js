import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { shout } from "../src/index.js";

describe("shout", () => {
  it("shouts by name", () => {
    assert.match(shout("ada"), /hey, ada!/);
  });
});
