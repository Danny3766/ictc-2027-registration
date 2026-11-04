import assert from "node:assert/strict";
import test from "node:test";
import { hashQueryCode, queryAlphabet, randomQueryCode, validPassword, validUsername, withNewQueryCode } from "./index.ts";

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

// The staff function keeps its own copy because Dashboard deploys each function separately.
test("staff query codes match what public lookups hash", async () => {
  const registration = await import("../registration/index.ts");
  assert.equal(queryAlphabet, registration.alphabet);
  assert.ok(registration.isValidCode(randomQueryCode()));
  const pepper = "p".repeat(32);
  assert.equal(await hashQueryCode("abcd2345", pepper), await registration.hashCode("abcd2345", pepper));
});

test("query code retry repeats only hash collisions", async () => {
  const pepper = "p".repeat(32);
  const collision = { error: { code: "23505", message: "registrations_query_code_hash_key" } };
  let calls = 0;
  const created = await withNewQueryCode(pepper, async () => (++calls < 3 ? collision : { data: [{ serial_no: 7 }] }));
  assert.equal(calls, 3);
  assert.deepEqual(created.data, [{ serial_no: 7 }]);
  assert.ok(await hashQueryCode(created.code, pepper));

  calls = 0;
  const duplicate = await withNewQueryCode(pepper, async () => {
    calls += 1;
    return { error: { code: "23505", message: "DUPLICATE_REQUEST" } };
  });
  assert.equal(calls, 1);
  assert.match(duplicate.error.message, /DUPLICATE_REQUEST/);

  calls = 0;
  const exhausted = await withNewQueryCode(pepper, async () => { calls += 1; return collision; });
  assert.equal(calls, 5);
  assert.equal(exhausted.error.code, "23505");
});
