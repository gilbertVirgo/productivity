import { assertEquals } from "@std/assert";
import { handle, type Deps, type Device } from "./push.ts";

const S = "11111111-1111-1111-1111-111111111111";
const jwt = (role: string) => `x.${btoa(JSON.stringify({ role })).replaceAll("=", "")}.y`;
const req = (body: unknown, role = "authenticated", method = "POST") =>
  new Request("http://x/push-activity", {
    method,
    headers: { Authorization: `Bearer ${jwt(role)}`, apikey: "anon-key", "Content-Type": "application/json" },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
const state = { status: "focused", projectName: "Northwind", colorHex: "#000000", countFrom: 1800000000, focusedSec: 600 };
const attrs = { sessionID: S };

function deps(devices: Device[], status = 200) {
  const sent: { token: string; payload: any }[] = [];
  const seen: string[] = [];
  const d: Deps = {
    devices: async (auth, apikey) => { seen.push(auth, apikey); return devices; },
    send: async (token, payload) => { sent.push({ token, payload }); return status; },
  };
  return { d, sent, seen };
}

Deno.test("start goes to push-to-start tokens with attributes and an alert", async () => {
  const { d, sent, seen } = deps([
    { push_to_start_token: "aa11", activity_token: null, activity_session_id: null },
    { push_to_start_token: null, activity_token: "bb22", activity_session_id: S },
    { push_to_start_token: "aa11", activity_token: null, activity_session_id: null }, // duplicate token
  ]);
  const r = await handle(req({ event: "start", session_id: S, attributes: attrs, content_state: state }), d);
  assertEquals(r.status, 200);
  assertEquals(await r.json(), { sent: 1, failed: 0 });
  assertEquals(seen, [`Bearer ${jwt("authenticated")}`, "anon-key"]);
  assertEquals(sent.length, 1);
  assertEquals(sent[0].token, "aa11");
  const aps = sent[0].payload.aps;
  assertEquals(aps.event, "start");
  assertEquals(aps["content-state"], state);
  assertEquals(aps["attributes-type"], "StintActivityAttributes");
  assertEquals(aps.attributes, attrs);
  assertEquals(aps.alert, { title: "Northwind", body: "Tracking on your Mac" });
  assertEquals(typeof aps.timestamp, "number");
});

Deno.test("update goes to every device's activity token", async () => {
  const { d, sent } = deps([
    { push_to_start_token: "aa11", activity_token: "bb22", activity_session_id: S },
    { push_to_start_token: null, activity_token: "cc33", activity_session_id: "22222222-2222-2222-2222-222222222222" }, // other stretch id
  ]);
  const r = await handle(req({ event: "update", session_id: S.toUpperCase(), content_state: state }), d);
  assertEquals(await r.json(), { sent: 2, failed: 0 });
  assertEquals(sent.map((s) => s.token), ["bb22", "cc33"]);
  assertEquals(sent[0].payload.aps.event, "update");
  assertEquals(sent[0].payload.aps.attributes, undefined);
  assertEquals(sent[0].payload.aps.alert, undefined);
});

Deno.test("end sets a dismissal date five minutes out", async () => {
  const { d, sent } = deps([{ push_to_start_token: null, activity_token: "bb22", activity_session_id: S }]);
  await handle(req({ event: "end", session_id: S, content_state: { status: "ended", remainingSec: 0 } }), d);
  const aps = sent[0].payload.aps;
  assertEquals(aps.event, "end");
  assertEquals(aps["dismissal-date"], aps.timestamp + 300);
});

Deno.test("APNs failures and non-hex tokens are not counted as sent", async () => {
  const { d, sent } = deps([
    { push_to_start_token: "aa11", activity_token: null, activity_session_id: null },
    { push_to_start_token: "../evil", activity_token: null, activity_session_id: null },
  ], 410);
  const r = await handle(req({ event: "start", session_id: S, attributes: attrs, content_state: state }), d);
  assertEquals(await r.json(), { sent: 0, failed: 1 });
  assertEquals(sent.map((s) => s.token), ["aa11"]);
});

Deno.test("error statuses", async () => {
  const { d } = deps([]);
  assertEquals((await handle(req({}, "authenticated", "GET"), d)).status, 405);
  assertEquals((await handle(req({ event: "update", session_id: S, content_state: state }, "anon"), d)).status, 401);
  assertEquals((await handle(req({ event: "nope", session_id: S, content_state: state }), d)).status, 400);
  assertEquals((await handle(req({ event: "start", session_id: S, content_state: state }), d)).status, 400); // no attributes
  assertEquals((await handle(req({ event: "update", session_id: 5, content_state: state }), d)).status, 400);
  assertEquals((await handle(req({ event: "update", session_id: S }), d)).status, 400);
  assertEquals((await handle(req({ event: "update", session_id: S, content_state: state }), null)).status, 503);
  const broken: Deps = { devices: async () => { throw new Error("down"); }, send: async () => 200 };
  assertEquals((await handle(req({ event: "update", session_id: S, content_state: state }), broken)).status, 502);
  const bad = new Request("http://x", { method: "POST", headers: { Authorization: `Bearer ${jwt("authenticated")}` }, body: "{" });
  assertEquals((await handle(bad, d)).status, 400);
});
