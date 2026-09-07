import test from "node:test";
import assert from "node:assert/strict";
import dcgPi, { checkCommand } from "../assets/dcg-pi.ts";

test("DCG checks an argv string without executing it as shell code", () => {
  let args: any;
  const result = checkCommand("git reset --hard", ((...call: any[]) => { args = call; return { status: 0 }; }) as any);
  assert.equal(result, undefined);
  assert.deepEqual(args[1], ["--robot", "test", "--", "git reset --hard"]);
  assert.equal(args[2].shell, undefined);
});

test("DCG denials and failures block; non-shell tools do not invoke DCG", () => {
  assert.deepEqual(checkCommand("test", (() => ({ status: 1, stdout: '{"reason":"denied","rule_id":"test.rule"}' })) as any), { block: true, reason: "denied [test.rule]" });
  assert.equal(checkCommand("test", (() => ({ status: 1, stdout: "bad JSON" })) as any)?.block, true);
  assert.equal(checkCommand("test", (() => ({ status: 3 })) as any)?.block, true);
  assert.equal(checkCommand("test", (() => { throw Error("missing binary"); }) as any)?.block, true);
  let handler: any;
  dcgPi({ on: (_name: string, fn: any) => { handler = fn; } });
  assert.equal(handler({ toolName: "write", input: { command: "ignored" } }), undefined);
});
