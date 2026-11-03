import assert from "node:assert/strict";
import test from "node:test";
import { alphabet, hashCode, isUuid, isValidCode, normalizeCode, randomCode } from "./index.ts";

test("query codes use exactly eight unambiguous characters", () => {
  for (let index = 0; index < 1_000; index += 1) {
    assert.match(randomCode(), new RegExp(`^[${alphabet}]{8}$`));
  }
});

test("query code input is case and whitespace insensitive", () => {
  assert.equal(normalizeCode(" A2 B3C\n"), "a2b3c");
  assert.equal(normalizeCode(null), "");
  assert.equal(isValidCode("a2b3c4d5"), true);
  assert.equal(isValidCode("a2b3c"), false);
});

test("query codes are stored as keyed hashes", async () => {
  const first = await hashCode("abc23", "a".repeat(32));
  assert.equal(first, await hashCode("abc23", "a".repeat(32)));
  assert.notEqual(first, await hashCode("abc23", "b".repeat(32)));
  assert.match(first, /^[0-9a-f]{64}$/);
});

test("request identifiers are validated", () => {
  assert.equal(isUuid("123e4567-e89b-42d3-a456-426614174000"), true);
  assert.equal(isUuid("123e4567-e89b-12d3-a456-426614174000"), false);
});
