import { assertEquals } from "@std/assert";
import { clean, handle, MAX_TRANSCRIPT, type Caller } from "./parse.ts";

const P = [{ id: "11111111-1111-1111-1111-111111111111", name: "Northwind" }];

// Gateway-verified JWTs: only the payload matters here.
const jwt = (role: string) => `x.${btoa(JSON.stringify({ role })).replaceAll("=", "")}.y`;
const req = (body: unknown, role = "authenticated", method = "POST") =>
  new Request("http://x/parse-tasks", {
    method,
    headers: { Authorization: `Bearer ${jwt(role)}`, "Content-Type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
const ok: Caller = async () => ({
  tasks: [
    { title: " Send invoice ", project_id: P[0].id, estimate_min: 15, estimate_guessed: false },
    { title: "   ", project_id: null, estimate_min: null, estimate_guessed: false },
    { title: "Call bank", project_id: "not-a-project", estimate_min: 0, estimate_guessed: true },
  ],
});

Deno.test("clean keeps good tasks, drops empty titles, nulls unknown project and bad estimate", () => {
  const raw = { tasks: [
    { title: "A", project_id: P[0].id, estimate_min: 30, estimate_guessed: true },
    { title: "", project_id: null, estimate_min: null, estimate_guessed: false },
    { title: "B", project_id: "nope", estimate_min: 2000, estimate_guessed: true },
    { title: "C", project_id: null, estimate_min: 12.5, estimate_guessed: false },
    "junk",
  ] };
  assertEquals(clean(raw, P), [
    { title: "A", project_id: P[0].id, estimate_min: 30, estimate_guessed: true },
    { title: "B", project_id: null, estimate_min: null, estimate_guessed: false },
    { title: "C", project_id: null, estimate_min: null, estimate_guessed: false },
  ]);
});

Deno.test("clean throws on a response without a tasks array", () => {
  let threw = false;
  try { clean({ nope: 1 }, P); } catch { threw = true; }
  assertEquals(threw, true);
});

Deno.test("200 with cleaned tasks", async () => {
  const r = await handle(req({ transcript: "send invoice, call bank", projects: P }), ok);
  assertEquals(r.status, 200);
  assertEquals(await r.json(), { tasks: [
    { title: "Send invoice", project_id: P[0].id, estimate_min: 15, estimate_guessed: false },
    { title: "Call bank", project_id: null, estimate_min: null, estimate_guessed: false },
  ] });
});

Deno.test("passes the transcript and only well-formed projects to Claude", async () => {
  let seen: unknown[] = [];
  const spy: Caller = async (t, p) => { seen = [t, p]; return { tasks: [] }; };
  await handle(req({ transcript: "  hi  ", projects: [...P, { id: 3 }, "x"] }), spy);
  assertEquals(seen, ["hi", P]);
});

Deno.test("error statuses", async () => {
  assertEquals((await handle(req({}, "authenticated", "GET"), ok)).status, 405);
  assertEquals((await handle(req({ transcript: "x" }, "anon"), ok)).status, 401);
  assertEquals((await handle(req({ transcript: "   " }), ok)).status, 400);
  assertEquals((await handle(req({ transcript: "a".repeat(MAX_TRANSCRIPT + 1) }), ok)).status, 413);
  assertEquals((await handle(req({ transcript: "é".repeat(MAX_TRANSCRIPT) }), ok)).status, 200);
  assertEquals((await handle(req({ transcript: "x" }), null)).status, 503);
  assertEquals((await handle(req({ transcript: "x" }), async () => { throw new Error("boom"); })).status, 502);
  assertEquals((await handle(req({ transcript: "x" }), async () => ({ bad: true }))).status, 502);
  const bad = new Request("http://x", { method: "POST", headers: { Authorization: `Bearer ${jwt("authenticated")}` }, body: "{" });
  assertEquals((await handle(bad, ok)).status, 400);
});
