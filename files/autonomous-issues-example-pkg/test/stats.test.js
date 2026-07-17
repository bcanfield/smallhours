import test from "node:test";
import assert from "node:assert/strict";
import { mean, sum } from "../src/stats.js";

test("sum adds numbers", () => {
  assert.equal(sum([1, 2, 3]), 6);
  assert.equal(sum([]), 0);
});

test("mean averages numbers", () => {
  assert.equal(mean([2, 4, 6]), 4);
});

test("mean throws on empty input", () => {
  assert.throws(() => mean([]));
});
