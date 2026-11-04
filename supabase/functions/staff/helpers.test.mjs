import assert from "node:assert/strict";
import test from "node:test";
import { nameKey, validPassword, validUsername } from "./index.ts";

test("staff password length is bounded before privileged update", () => {
  assert.equal(validPassword("a".repeat(11)), false);
  assert.equal(validPassword("a".repeat(12)), true);
  assert.equal(validPassword("a".repeat(72)), true);
  assert.equal(validPassword("a".repeat(73)), false);
  assert.equal(validPassword(null), false);
  assert.equal(validPassword("密".repeat(24)), true);
  assert.equal(validPassword("密".repeat(25)), false);
});

test("staff usernames have a stable internal identity format", () => {
  assert.equal(validUsername("lin_sen_01"), true);
  assert.equal(validUsername("ABCD"), false);
  assert.equal(validUsername("a"), false);
  assert.equal(validUsername("abc@somewhere"), false);
});

test("staff search uses the same name key as the database lookup", () => {
  // Expected values match public.registration_name_key in the local PostgreSQL checks.
  assert.equal(nameKey(" David  Wang "), "davidwang");
  assert.equal(nameKey("王　小明"), "王小明");
  assert.equal(nameKey("Ｊｏｈｎ Smith"), "johnsmith");
  assert.equal(nameKey("王\u200B小明\uFEFF"), "王小明");
});
