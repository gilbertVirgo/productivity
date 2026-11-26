# Live Activity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a session starts on the Mac, a Live Activity (lock screen + Dynamic Island) appears on the iPhone. It shows the project, the countdown, the current task and the on/off-task state, and it ends when the session ends.

**Architecture:**
- The Mac's `AppState` emits a `LivePush` on three occasions: when a session starts, when the phone-visible state changes (break, off task, task, a pause that shifts the end time), and when the session closes.
- `SyncCoordinator` sends each `LivePush` in order to a new edge function, `push-activity`.
- `push-activity` reads the user's iOS device tokens from the `device` table using the caller's own JWT, so RLS limits it to the caller's rows. It then sends APNs Live Activity pushes:
  - push-to-start for `start`;
  - the activity's own token for `update` and `end`.
- The phone uploads its push-to-start token and the current activity's token to its `device` row.
- While the phone app is in the foreground, it also starts, updates and ends the activity itself from the realtime session feed. That way the feature works before the APNs key exists, and it fills gaps if a push is lost.
- Countdowns use `Text(timerInterval:)`, so pushes happen only on state changes.

**Tech Stack:**
- Deno 2 with `jsr:@panva/jose` (ES256 APNs JWT) and native `fetch` (HTTP/2).
- Swift 6, ActivityKit (iOS 17.2+), WidgetKit, SwiftData.
- supabase-swift 2.55 `functions.invoke`.

**Spec:** `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md`:
- §3 Live Activity row;
- §5 `device` table;
- §6.9 Live Activity;
- §8 edge function tests and the manual checklist "Live Activity start/end".

## Global Constraints

- iPhone app: SwiftUI, iOS 17.2+ (needed for Live Activity push-to-start).
- Live Activity: ActivityKit. The timer is drawn with `Text(timerInterval:)`, so there are no per-second pushes.
- Live Activity shows the project, the countdown, the current task and the on-task/off-task state.
- Swift 6 strict concurrency.
- SwiftPM tests: `cd Shared && swift test --disable-sandbox`. The flag is mandatory.
- Deno edge functions get one Deno test file each. A stubbed external call stands in for the network.
- Never create or read `supabase/functions/.env`, and never handle the APNs key. The user adds it.
- Apple account: the user approved adding the **Push Notifications** capability to App ID `dev.stint.ios`. Nothing else may change on the account.

**Rulings baked into this plan (spec deviations):**
- **The Mac calls `push-activity` directly, instead of DB webhooks** (spec §6.9: session insert/update and session_event insert triggers).
  - The Mac is the only writer of sessions, and it already holds the user's JWT.
  - This avoids storing a service secret in Postgres (pg_net plus vault).
  - The function never needs the service role, because RLS on `device` scopes the token lookup.
  - Cost if wrong: a push is lost when the Mac's call fails. The phone's foreground reconcile covers that case.
- **New `device` columns `activity_token` and `activity_session_id`.** APNs updates and ends go to the token of each individual activity, and spec §5 only lists `apns_token` and `push_to_start_token`.
- **`endsAt` in the content state is a `Double` of Unix seconds, not a `Date`.** ActivityKit decodes push payloads with a default `JSONDecoder` (reference date 2001), so a plain number avoids any date-format mismatch between the Mac, the function and the phone.
- **Ended activities stay on the lock screen for 5 minutes** (`dismissal-date` = now + 300 s), showing "Session ended".
- **The same pure state rule runs on both sides.** The Mac's `push-activity` path and the phone's local reconcile both build state with `LiveSessionState.make`.

---

### Task 1: `push-activity` edge function and `device` columns

**Files:**
- Create: `supabase/migrations/20261126000008_device_activity.sql`
- Create: `supabase/functions/_shared/auth.ts`
- Modify: `supabase/functions/parse-tasks/parse.ts`, replacing its private `role()` with an import from `../_shared/auth.ts`
- Create: `supabase/functions/push-activity/push.ts`
- Create: `supabase/functions/push-activity/apns.ts`
- Create: `supabase/functions/push-activity/index.ts`
- Create: `supabase/functions/push-activity/push_test.ts`
- Create (via `deno add`): `supabase/functions/push-activity/deno.json`
- Modify: `supabase/functions/.env.example`
- Modify: `supabase/config.jsonc`, adding `"push-activity": { "verify_jwt": true }` to the existing `"functions"` block

**Interfaces:**
- Produces the HTTP contract that Task 4 relies on:
  - Request: `POST /functions/v1/push-activity` with the user's JWT and a JSON body:
    - `{"event": "start"|"update"|"end", "session_id": uuid-string, "attributes": {...} (required for start), "content_state": {...}}`
    - `attributes` and `content_state` are forwarded to APNs verbatim.
  - `200 {"sent": Int, "failed": Int}`.
  - Errors return `{"error": code}`:
    - 405 `method`
    - 401 `auth`
    - 400 `bad_json` / `bad_request`
    - 503 `push_unavailable` (no APNs config)
    - 502 `devices_failed`
- Produces DB columns that Task 3 writes: `public.device.activity_token text` and `public.device.activity_session_id uuid`.

- [ ] **Step 1: Migration** `supabase/migrations/20261126000008_device_activity.sql`:

```sql
-- Live Activity (plan 7): APNs updates/ends go to each activity's own push token.
alter table public.device
  add column activity_token text,
  add column activity_session_id uuid;
```

  - Apply it without wiping local data: `supabase migration up` (use `dangerouslyDisableSandbox`).
  - **Never run `supabase db reset`.** The local DB holds the user's test accounts.
  - Then run `supabase test db` and confirm the existing pgTAP suites still pass.

- [ ] **Step 2: Shared auth helper** `supabase/functions/_shared/auth.ts`:

```ts
/** The gateway has already verified the JWT (verify_jwt = true in config.jsonc); this only reads its claims. */
export function role(req: Request): string | null {
  const token = req.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
  try {
    const b64 = token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(atob(b64 + "=".repeat((4 - b64.length % 4) % 4))).role ?? null;
  } catch { return null; }
}
```

  In `supabase/functions/parse-tasks/parse.ts`:
  - delete the local `role` function and its doc comment;
  - add `import { role } from "../_shared/auth.ts";` at the top;
  - run `cd supabase/functions/parse-tasks && deno test`. Expected: 6 tests still pass.

- [ ] **Step 3: Add dependencies.**

```bash
mkdir -p supabase/functions/push-activity && cd supabase/functions/push-activity
deno add jsr:@panva/jose jsr:@std/assert
```

- [ ] **Step 4: Write the failing test** `supabase/functions/push-activity/push_test.ts`:

```ts
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
const state = { status: "focused", endsAt: 1800000600, remainingSec: 600 };
const attrs = { sessionID: S, projectName: "Northwind", plannedMin: 50 };

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
  assertEquals(aps.alert, { title: "Northwind", body: "Session started on your Mac" });
  assertEquals(typeof aps.timestamp, "number");
});

Deno.test("update goes only to this session's activity tokens, ids compared case-insensitively", async () => {
  const { d, sent } = deps([
    { push_to_start_token: "aa11", activity_token: "bb22", activity_session_id: S },
    { push_to_start_token: null, activity_token: "cc33", activity_session_id: "22222222-2222-2222-2222-222222222222" },
  ]);
  const r = await handle(req({ event: "update", session_id: S.toUpperCase(), content_state: state }), d);
  assertEquals(await r.json(), { sent: 1, failed: 0 });
  assertEquals(sent.map((s) => s.token), ["bb22"]);
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
```

- [ ] **Step 5: Run it to see it fail.** Run `cd supabase/functions/push-activity && deno test`. Expected: FAIL, module `./push.ts` not found.

- [ ] **Step 6: Implement** `supabase/functions/push-activity/push.ts`:

```ts
import { role } from "../_shared/auth.ts";

export type Device = { push_to_start_token: string | null; activity_token: string | null; activity_session_id: string | null };
export type Deps = {
  /** The caller's own rows (RLS), read with the caller's Authorization and apikey headers. */
  devices: (auth: string, apikey: string) => Promise<Device[]>;
  /** Sends one APNs request; returns the HTTP status. */
  send: (token: string, payload: unknown) => Promise<number>;
};

const EVENTS = ["start", "update", "end"];
const HEX = /^[0-9a-fA-F]{16,200}$/;
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

export async function handle(req: Request, deps: Deps | null): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method" });
  if (role(req) !== "authenticated") return json(401, { error: "auth" });
  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }
  const { event, session_id, attributes, content_state } = isObject(body) ? body : {};
  if (typeof event !== "string" || !EVENTS.includes(event) || typeof session_id !== "string" ||
      !isObject(content_state) || (event === "start" && !isObject(attributes))) {
    return json(400, { error: "bad_request" });
  }
  if (!deps) return json(503, { error: "push_unavailable" });

  let devices: Device[];
  try {
    devices = await deps.devices(req.headers.get("Authorization") ?? "", req.headers.get("apikey") ?? "");
  } catch (e) {
    console.error("push-activity devices:", e instanceof Error ? e.message : e);
    return json(502, { error: "devices_failed" });
  }
  const sid = session_id.toLowerCase(); // Swift sends upper-case UUIDs; Postgres returns lower-case
  const tokens = [...new Set(devices.map((d) =>
    event === "start" ? d.push_to_start_token : d.activity_session_id?.toLowerCase() === sid ? d.activity_token : null
  ).filter((t): t is string => typeof t === "string" && HEX.test(t)))];

  const now = Math.floor(Date.now() / 1000);
  const aps: Record<string, unknown> = { timestamp: now, event, "content-state": content_state };
  if (event === "start") {
    const a = attributes as Record<string, unknown>;
    aps["attributes-type"] = "StintActivityAttributes";
    aps.attributes = a;
    aps.alert = { title: typeof a.projectName === "string" ? a.projectName : "Stint", body: "Session started on your Mac" };
  }
  if (event === "end") aps["dismissal-date"] = now + 300;

  const statuses = await Promise.all(tokens.map((t) => deps.send(t, { aps }).catch(() => 0)));
  const sent = statuses.filter((s) => s === 200).length;
  return json(200, { sent, failed: statuses.length - sent });
}
```

- [ ] **Step 7: Run the tests.** Run `deno test`. Expected: all 5 tests pass.

- [ ] **Step 8: APNs sender** `supabase/functions/push-activity/apns.ts`. It isn't unit-tested, because `handle` takes `send` as a parameter.

```ts
import { importPKCS8, SignJWT } from "@panva/jose";

export type ApnsConfig = { keyId: string; teamId: string; privateKey: string; topic: string; host: string };

/** Token-based APNs auth (ES256). Apple wants the JWT reused for 20–60 min, so it's cached for 50. */
export function apnsSender(cfg: ApnsConfig): (token: string, payload: unknown) => Promise<number> {
  const key = importPKCS8(cfg.privateKey.replaceAll("\\n", "\n"), "ES256");
  let cached: { jwt: string; at: number } | null = null;
  async function bearer(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (cached && now - cached.at < 50 * 60) return cached.jwt;
    const jwt = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: cfg.keyId })
      .setIssuer(cfg.teamId).setIssuedAt(now).sign(await key);
    cached = { jwt, at: now };
    return jwt;
  }
  return async (token, payload) => {
    const r = await fetch(`https://${cfg.host}/3/device/${token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await bearer()}`,
        "apns-push-type": "liveactivity",
        "apns-topic": `${cfg.topic}.push-type.liveactivity`,
        "apns-priority": "10",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (r.ok) await r.body?.cancel();
    else console.error("apns", r.status, await r.text());
    return r.status;
  };
}
```

  If `deno check` can't resolve `@panva/jose`, use the import-map name that `deno add` wrote to `deno.json`.

- [ ] **Step 9: Entry point** `supabase/functions/push-activity/index.ts`:

```ts
import { handle, type Deps, type Device } from "./push.ts";
import { apnsSender } from "./apns.ts";

const env = (k: string) => Deno.env.get(k) ?? "";
const url = env("SUPABASE_URL"); // injected by the edge runtime

const devices = async (auth: string, apikey: string): Promise<Device[]> => {
  const r = await fetch(`${url}/rest/v1/device?select=push_to_start_token,activity_token,activity_session_id&platform=eq.ios`,
    { headers: { Authorization: auth, apikey } });
  if (!r.ok) throw new Error(`device lookup ${r.status}`);
  return await r.json();
};

const configured = env("APNS_KEY_ID") && env("APNS_TEAM_ID") && env("APNS_PRIVATE_KEY");
const deps: Deps | null = configured
  ? { devices, send: apnsSender({
      keyId: env("APNS_KEY_ID"), teamId: env("APNS_TEAM_ID"), privateKey: env("APNS_PRIVATE_KEY"),
      topic: env("APNS_TOPIC") || "dev.stint.ios", host: env("APNS_HOST") || "api.sandbox.push.apple.com",
    }) }
  : null; // no key yet: 503, and the phone's own foreground reconcile keeps the activity going

Deno.serve((req) => handle(req, deps));
```

- [ ] **Step 10: Secrets template and config.**
  - Append to `supabase/functions/.env.example`:
    ```
    # Live Activity pushes (plan 7). From developer.apple.com → Keys → a key with Apple Push Notifications service.
    # APNS_PRIVATE_KEY is the .p8 file's contents on one line with \n for newlines.
    APNS_KEY_ID=
    APNS_TEAM_ID=63Q7M3DVRK
    APNS_PRIVATE_KEY=
    # Optional: APNS_TOPIC=dev.stint.ios  APNS_HOST=api.sandbox.push.apple.com (api.push.apple.com for TestFlight/App Store)
    ```
  - In `supabase/config.jsonc`, change the `"functions"` block to:
    ```jsonc
      "functions": {
        // role() in _shared/auth.ts trusts the JWT payload only because the gateway verifies the signature.
        // Never set these to false.
        "parse-tasks": { "verify_jwt": true },
        "push-activity": { "verify_jwt": true },
      },
    ```

- [ ] **Step 11: Check types and serve locally.** Use `dangerouslyDisableSandbox` for supabase, docker and curl.

```bash
cd supabase/functions/push-activity && deno check index.ts && deno test && cd ../parse-tasks && deno test && cd ../../..
supabase stop && supabase start
ANON=$(supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"/\1/p')
curl -s -w ' %{http_code}\n' -X POST http://127.0.0.1:54321/functions/v1/push-activity \
  -H "Authorization: Bearer $ANON" -H 'Content-Type: application/json' -d '{"event":"update","session_id":"x","content_state":{}}'
```

  Expected: `{"error":"auth"} 401`. If the realtime logs loop on `ReplicationSlotBeingUsed`, run `supabase stop && supabase start` again.

- [ ] **Step 12: Commit.**

```bash
git add supabase/migrations/20261126000008_device_activity.sql supabase/functions/_shared supabase/functions/parse-tasks/parse.ts \
  supabase/functions/push-activity supabase/functions/.env.example supabase/config.jsonc
git commit -m "feat(fn): push-activity edge function for Live Activity pushes"
```

---

### Task 2: Shared Live Activity state, push body and device row

**Files:**
- Create: `Shared/Sources/Core/LiveSession.swift`
- Create: `Shared/Tests/CoreTests/LiveSessionTests.swift`
- Modify: `Shared/Sources/StintData/Sync/Rows.swift` (append `DeviceRow`)
- Create: `Shared/Sources/StintData/Sync/LiveActivitySync.swift`
- Create: `Shared/Tests/StintDataTests/DeviceRowTests.swift`

**Interfaces:**
- Consumes: Task 1's HTTP contract and the `device` columns.
- Produces (Tasks 3 and 4 rely on these exact names):
  - **`Core.LiveSessionState`:**
    - `public struct LiveSessionState: Codable, Hashable, Sendable`
    - fields `status: Status`, `endsAt: Double?`, `remainingSec: Int`, `taskTitle: String?`
    - `enum Status: String, Codable, Sendable { case focused, offTask = "off_task", onBreak = "on_break", ended }`
    - `static func make(remainingSec: Int, onBreak: Bool, offTask: Bool, taskTitle: String?, now: Date) -> LiveSessionState`
    - `static func ended(taskTitle: String?) -> LiveSessionState`
    - `var endsDate: Date?`
    - `func differs(from: LiveSessionState) -> Bool`
  - **`Core.LiveSessionInfo`:** `public struct LiveSessionInfo: Codable, Hashable, Sendable` with `sessionID: String`, `projectName: String`, `plannedMin: Int`. These are the Live Activity attributes on the wire.
  - **`Core.LivePush`:**
    - `public struct LivePush: Encodable, Equatable, Sendable`
    - `event: Event` (`enum Event: String { start, update, end }`), `sessionID: UUID`, `attributes: LiveSessionInfo?`, `contentState: LiveSessionState`
    - wire keys `event`, `session_id`, `attributes`, `content_state`
  - **`StintData.DeviceRow`:** `public struct DeviceRow: Codable, Sendable, Equatable`, with a public `init(id:userID:updatedAt:platform:pushToStartToken:activityToken:activitySessionID:)`.
  - **On `SyncEngine` (`@MainActor`):**
    - `func pushActivity(_ push: LivePush) async throws`
    - `func saveDevice(_ row: DeviceRow) async throws`

- [ ] **Step 1: Write the failing Core test** `Shared/Tests/CoreTests/LiveSessionTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite struct LiveSessionTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func makeStates() {
        let f = LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: "Invoice", now: now)
        #expect(f.status == .focused && f.endsAt == 1_800_000_600 && f.remainingSec == 600 && f.taskTitle == "Invoice")
        #expect(f.endsDate == now.addingTimeInterval(600))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: true, taskTitle: nil, now: now).status == .offTask)
        let b = LiveSessionState.make(remainingSec: 600, onBreak: true, offTask: true, taskTitle: nil, now: now)
        #expect(b.status == .onBreak && b.endsAt == nil && b.endsDate == nil && b.remainingSec == 600)
        let e = LiveSessionState.ended(taskTitle: "x")
        #expect(e.status == .ended && e.endsAt == nil && e.remainingSec == 0 && e.taskTitle == "x")
    }

    @Test func differsIgnoresSmallDrift() {
        let a = LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: nil, now: now)
        // Counting down while focused keeps the same end time.
        #expect(!LiveSessionState.make(remainingSec: 590, onBreak: false, offTask: false, taskTitle: nil, now: now.addingTimeInterval(10)).differs(from: a))
        // A pause pushed the end time out by a minute.
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: nil, now: now.addingTimeInterval(60)).differs(from: a))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: true, taskTitle: nil, now: now).differs(from: a))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: true, offTask: false, taskTitle: nil, now: now).differs(from: a))
        #expect(LiveSessionState.make(remainingSec: 600, onBreak: false, offTask: false, taskTitle: "New", now: now).differs(from: a))
    }

    @Test func wireShape() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let p = LivePush(event: .start, sessionID: id,
                         attributes: LiveSessionInfo(sessionID: id.uuidString, projectName: "Northwind", plannedMin: 50),
                         contentState: .make(remainingSec: 60, onBreak: false, offTask: false, taskTitle: nil, now: now))
        let o = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        #expect(Set(o.keys) == ["event", "session_id", "attributes", "content_state"])
        #expect(o["event"] as? String == "start")
        #expect(o["session_id"] as? String == id.uuidString)
        let attrs = try #require(o["attributes"] as? [String: Any])
        #expect(Set(attrs.keys) == ["sessionID", "projectName", "plannedMin"])
        let cs = try #require(o["content_state"] as? [String: Any])
        #expect(cs["status"] as? String == "focused")
        #expect(cs["endsAt"] as? Double == 1_800_000_060)
        #expect(cs["remainingSec"] as? Int == 60)
        let back = try JSONDecoder().decode(LiveSessionState.self, from: JSONSerialization.data(withJSONObject: cs))
        #expect(back == p.contentState)
        let update = LivePush(event: .update, sessionID: id, attributes: nil, contentState: .ended(taskTitle: nil))
        let u = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(update)) as? [String: Any])
        #expect(u["attributes"] == nil && u["event"] as? String == "update")
    }
}
```

- [ ] **Step 2: Run it to see it fail.** Run `cd Shared && swift test --disable-sandbox --filter LiveSessionTests`. Expected: FAIL, `cannot find 'LiveSessionState' in scope`.

- [ ] **Step 3: Implement** `Shared/Sources/Core/LiveSession.swift`:

```swift
import Foundation

/// What the Live Activity shows (spec §6.9). Same JSON on the Mac (push body), in APNs (`content-state`)
/// and in ActivityKit (`ContentState`). `endsAt` is Unix seconds, not a Date, so no date-format can disagree.
public struct LiveSessionState: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case focused, offTask = "off_task", onBreak = "on_break", ended }
    public var status: Status
    /// When the planned length runs out if nothing pauses it; nil while on a break (the countdown is paused).
    public var endsAt: Double?
    public var remainingSec: Int
    public var taskTitle: String?

    public init(status: Status, endsAt: Double?, remainingSec: Int, taskTitle: String?) {
        self.status = status; self.endsAt = endsAt; self.remainingSec = remainingSec; self.taskTitle = taskTitle
    }

    public static func make(remainingSec: Int, onBreak: Bool, offTask: Bool, taskTitle: String?, now: Date) -> LiveSessionState {
        LiveSessionState(status: onBreak ? .onBreak : offTask ? .offTask : .focused,
                         endsAt: onBreak ? nil : (now.timeIntervalSince1970 + Double(remainingSec)).rounded(),
                         remainingSec: remainingSec, taskTitle: taskTitle)
    }

    public static func ended(taskTitle: String?) -> LiveSessionState {
        LiveSessionState(status: .ended, endsAt: nil, remainingSec: 0, taskTitle: taskTitle)
    }

    public var endsDate: Date? { endsAt.map { Date(timeIntervalSince1970: $0) } }

    /// Worth a push: anything visible changed, or the end time moved by more than 30 s (a pause or sleep).
    public func differs(from o: LiveSessionState) -> Bool {
        if status != o.status || taskTitle != o.taskTitle { return true }
        switch (endsAt, o.endsAt) {
        case let (a?, b?): return abs(a - b) > 30
        case (nil, nil): return false
        default: return true
        }
    }
}

/// Live Activity attributes on the wire. Property names must match `StintActivityAttributes` on iOS.
public struct LiveSessionInfo: Codable, Hashable, Sendable {
    public var sessionID: String
    public var projectName: String
    public var plannedMin: Int
    public init(sessionID: String, projectName: String, plannedMin: Int) {
        self.sessionID = sessionID; self.projectName = projectName; self.plannedMin = plannedMin
    }
}

/// Body of `POST /functions/v1/push-activity`.
public struct LivePush: Encodable, Equatable, Sendable {
    public enum Event: String, Encodable, Sendable { case start, update, end }
    public var event: Event
    public var sessionID: UUID
    public var attributes: LiveSessionInfo?
    public var contentState: LiveSessionState
    public init(event: Event, sessionID: UUID, attributes: LiveSessionInfo?, contentState: LiveSessionState) {
        self.event = event; self.sessionID = sessionID; self.attributes = attributes; self.contentState = contentState
    }
    enum CodingKeys: String, CodingKey { case event, sessionID = "session_id", attributes, contentState = "content_state" }
}
```

- [ ] **Step 4: Run the Core tests.** Run `cd Shared && swift test --disable-sandbox --filter LiveSessionTests`. Expected: 3 tests pass.

- [ ] **Step 5: Write the failing StintData test** `Shared/Tests/StintDataTests/DeviceRowTests.swift`:

```swift
import Testing
import Foundation
@testable import StintData

@Suite struct DeviceRowTests {
    @Test func encodesSnakeCaseWithExplicitNulls() throws {
        let id = UUID(), uid = UUID()
        let row = DeviceRow(id: id, userID: uid, updatedAt: Date(timeIntervalSince1970: 0), platform: "ios",
                            pushToStartToken: "aa11", activityToken: nil, activitySessionID: nil)
        let o = try #require(try JSONSerialization.jsonObject(with: SyncCoding.encoder.encode(row)) as? [String: Any])
        #expect(Set(o.keys) == ["id", "user_id", "updated_at", "platform", "push_to_start_token", "activity_token", "activity_session_id"])
        #expect(o["platform"] as? String == "ios" && o["push_to_start_token"] as? String == "aa11")
        #expect(o["activity_token"] is NSNull && o["activity_session_id"] is NSNull) // clearing reaches the server
    }
}
```

- [ ] **Step 6: Run it to see it fail.** Run `cd Shared && swift test --disable-sandbox --filter DeviceRowTests`. Expected: FAIL, `cannot find 'DeviceRow' in scope`.

- [ ] **Step 7: Implement.** Append to `Shared/Sources/StintData/Sync/Rows.swift`:

```swift
/// The phone's push tokens (plan 7). Written by the phone only; read by `push-activity` through RLS.
public struct DeviceRow: Codable, Sendable, Equatable {
    public var id: UUID, userID: UUID, updatedAt: Date
    public var platform: String
    public var pushToStartToken: String?, activityToken: String?, activitySessionID: UUID?
    public init(id: UUID, userID: UUID, updatedAt: Date, platform: String,
                pushToStartToken: String?, activityToken: String?, activitySessionID: UUID?) {
        self.id = id; self.userID = userID; self.updatedAt = updatedAt; self.platform = platform
        self.pushToStartToken = pushToStartToken; self.activityToken = activityToken; self.activitySessionID = activitySessionID
    }
    enum CodingKeys: String, CodingKey {
        case id, userID = "user_id", updatedAt = "updated_at", platform
        case pushToStartToken = "push_to_start_token", activityToken = "activity_token", activitySessionID = "activity_session_id"
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(userID, forKey: .userID); try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(platform, forKey: .platform)
        try c.encode(pushToStartToken, forKey: .pushToStartToken); try c.encode(activityToken, forKey: .activityToken)
        try c.encode(activitySessionID, forKey: .activitySessionID)
    }
}
```

  Create `Shared/Sources/StintData/Sync/LiveActivitySync.swift`:

```swift
import Foundation
import Supabase
import Core

extension SyncEngine {
    /// Asks `push-activity` to push this change to the user's iPhones. Throws on any non-2xx (503 = no APNs key yet).
    public func pushActivity(_ push: LivePush) async throws {
        try await client.functions.invoke("push-activity", options: FunctionInvokeOptions(body: push))
    }

    /// Upserts this phone's push tokens. `updated_at` must be now: the server skips older writes.
    public func saveDevice(_ row: DeviceRow) async throws {
        try await client.from("device").upsert([row], onConflict: "id", returning: .minimal).execute()
    }
}
```

  If the non-generic `invoke(_:options:)` overload doesn't exist in supabase-swift 2.55, decode into `struct PushResult: Decodable { let sent: Int; let failed: Int }` with `decoder: JSONDecoder()` instead.

- [ ] **Step 8: Run all SwiftPM tests.** Run `cd Shared && swift test --disable-sandbox`. Expected: everything passes, including the 2 new suites.

- [ ] **Step 9: Commit.**

```bash
git add Shared/Sources/Core/LiveSession.swift Shared/Tests/CoreTests/LiveSessionTests.swift Shared/Sources/StintData/Sync/Rows.swift \
  Shared/Sources/StintData/Sync/LiveActivitySync.swift Shared/Tests/StintDataTests/DeviceRowTests.swift
git commit -m "feat(live): shared Live Activity state, push body and device row"
```

---

### Task 3: iPhone Live Activity (UI, tokens, foreground reconcile)

**Files:**
- Create: `SharedUI/StintActivity.swift` (ActivityKit attributes, iOS only)
- Create: `Widgets/LiveSessionWidget.swift`
- Modify: `Widgets/StintWidgets.swift` (add `LiveSessionWidget()` to the bundle)
- Create: `iOS/LiveActivities.swift`
- Modify: `iOS/PhoneSync.swift` (token upload and reconcile after each refresh)
- Create: `iOSTests/LiveActivityTests.swift`
- Modify: `project.yml`:
  - add `SharedUI/StintActivity.swift` to the widgets' source list;
  - StintPhone info: `NSSupportsLiveActivities: true`;
  - StintPhone entitlements: `aps-environment: development`;
  - StintMac: add `StintActivity.swift` to its SharedUI `excludes`.

**Interfaces:**
- Consumes from Task 2:
  - `LiveSessionState`, `LiveSessionInfo`;
  - `DeviceRow(id:userID:updatedAt:platform:pushToStartToken:activityToken:activitySessionID:)`;
  - `SyncEngine.saveDevice(_:)`.
- Consumes from existing code:
  - `RunningSession`: `id`, `projectID`, `firstTaskID`, `plannedMin`, `onBreak`, `offTask`, `remainingSec(at:)`;
  - `PhoneSync.running`;
  - `remainingText(_:)` in `SharedUI/Theme.swift`;
  - `Theme.warn`.
- Produces:
  - `struct StintActivityAttributes: ActivityAttributes` with `ContentState = LiveSessionState` and properties `sessionID: String`, `projectName: String`, `plannedMin: Int`. The attributes-type name `"StintActivityAttributes"` must match the push.
  - `@MainActor final class LiveActivities`, with:
    - `tokens`
    - `onTokens`
    - `startObserving()`
    - `reconcile(running:projectName:taskTitle:now:) async`
    - `nonisolated static func plan(existing: [(id: String, sessionID: String)], runningSessionID: String?) -> (start: Bool, end: Set<String>)`

- [ ] **Step 1: Write the failing test** `iOSTests/LiveActivityTests.swift`:

```swift
import Testing
import Foundation
import Core
@testable import Stint

@Suite struct LiveActivityTests {
    @Test func attributesMatchTheWireShapeTheMacSends() throws {
        let enc = JSONEncoder(); enc.outputFormatting = .sortedKeys
        let a = try enc.encode(StintActivityAttributes(sessionID: "S", projectName: "Northwind", plannedMin: 25))
        let b = try enc.encode(LiveSessionInfo(sessionID: "S", projectName: "Northwind", plannedMin: 25))
        #expect(a == b)
    }

    @Test func planStartsOneActivityAndEndsTheRest() {
        let none = LiveActivities.plan(existing: [], runningSessionID: "A")
        #expect(none.start && none.end.isEmpty)
        let dupes = LiveActivities.plan(existing: [("1", "A"), ("2", "A"), ("3", "B")], runningSessionID: "A")
        #expect(!dupes.start && dupes.end == ["2", "3"])
        let over = LiveActivities.plan(existing: [("1", "A")], runningSessionID: nil)
        #expect(!over.start && over.end == ["1"])
    }

    @Test func hexToken() {
        #expect(Data([0x00, 0xab, 0x10]).hexString == "00ab10")
    }
}
```

- [ ] **Step 2: Attributes** `SharedUI/StintActivity.swift`:

```swift
#if canImport(ActivityKit)
import ActivityKit
import Core

/// The type name is part of the APNs push-to-start payload ("attributes-type"); don't rename it.
/// Property names must match `LiveSessionInfo` (LiveActivityTests checks this).
struct StintActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveSessionState
    var sessionID: String
    var projectName: String
    var plannedMin: Int
}
#endif
```

- [ ] **Step 3: Live Activity UI** `Widgets/LiveSessionWidget.swift`:

```swift
import ActivityKit
import WidgetKit
import SwiftUI
import Core

struct LiveSessionWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StintActivityAttributes.self) { ctx in
            LockScreen(attrs: ctx.attributes, state: ctx.state).padding()
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Text(ctx.attributes.projectName).font(.headline).lineLimit(1) }
                DynamicIslandExpandedRegion(.trailing) { Clock(state: ctx.state).font(.title3) }
                DynamicIslandExpandedRegion(.bottom) { Status(state: ctx.state) }
            } compactLeading: {
                Image(systemName: symbol(ctx.state.status)).foregroundStyle(tint(ctx.state.status))
            } compactTrailing: {
                Clock(state: ctx.state).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: symbol(ctx.state.status)).foregroundStyle(tint(ctx.state.status))
            }
        }
    }
}

private struct LockScreen: View {
    let attrs: StintActivityAttributes
    let state: LiveSessionState
    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(attrs.projectName).font(.headline).lineLimit(1)
                if let task = state.taskTitle { Text(task).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                Status(state: state)
            }
            Spacer()
            Clock(state: state).font(.system(size: 34, weight: .semibold))
        }
    }
}

/// Counts down without pushes. Paused (break) or past the end: a static remaining time.
private struct Clock: View {
    let state: LiveSessionState
    var body: some View {
        Group {
            if let end = state.endsDate, end > .now {
                Text(timerInterval: Date.now...end, countsDown: true)
            } else if state.status == .ended {
                Image(systemName: "checkmark.circle.fill")
            } else {
                Text(remainingText(state.remainingSec))
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

private struct Status: View {
    let state: LiveSessionState
    var body: some View {
        Text(label(state.status)).font(.caption.weight(.semibold)).foregroundStyle(tint(state.status))
    }
}

private func label(_ s: LiveSessionState.Status) -> String {
    switch s {
    case .focused: "Focused"
    case .offTask: "Off task"
    case .onBreak: "On break"
    case .ended: "Session ended"
    }
}

private func symbol(_ s: LiveSessionState.Status) -> String {
    switch s {
    case .focused: "timer"
    case .offTask: "exclamationmark.circle"
    case .onBreak: "cup.and.saucer"
    case .ended: "checkmark.circle"
    }
}

private func tint(_ s: LiveSessionState.Status) -> Color { s == .offTask ? Theme.warn : .accentColor }
```

  In `Widgets/StintWidgets.swift`, change the bundle body to `var body: some Widget { WeekWidget(); TodayWidget(); StartWidget(); LiveSessionWidget() }`.

  `remainingText` and `Theme` live in `SharedUI/Theme.swift`, which the widgets target already compiles. If either symbol name differs there, use the real one.

- [ ] **Step 4: Activity manager** `iOS/LiveActivities.swift`:

```swift
import ActivityKit
import Foundation
import Core
import StintData

/// Live Activity on the phone (spec §6.9):
/// - uploads push tokens so `push-activity` can start, update and end it from the Mac;
/// - while the app is in the foreground, also starts, updates and ends it from the realtime session feed.
@MainActor
final class LiveActivities {
    struct Tokens: Equatable { var pushToStart: String?; var activity: String?; var activitySessionID: UUID? }
    private(set) var tokens = Tokens()
    var onTokens: ((Tokens) -> Void)?
    private var observing = false
    private var watched: Set<String> = []

    func startObserving() {
        guard !observing else { return }
        observing = true
        Task { [weak self] in
            for await data in Activity<StintActivityAttributes>.pushToStartTokenUpdates {
                guard let self else { return }
                self.tokens.pushToStart = data.hexString
                self.onTokens?(self.tokens)
            }
        }
        Task { [weak self] in
            for await activity in Activity<StintActivityAttributes>.activityUpdates { self?.watch(activity) }
        }
        for activity in Activity<StintActivityAttributes>.activities { watch(activity) }
    }

    private func watch(_ activity: Activity<StintActivityAttributes>) {
        guard watched.insert(activity.id).inserted else { return }
        let sessionID = UUID(uuidString: activity.attributes.sessionID)
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                guard let self else { return }
                self.tokens.activity = data.hexString
                self.tokens.activitySessionID = sessionID
                self.onTokens?(self.tokens)
            }
        }
    }

    /// Makes the activities match the session feed: one for the running session, none otherwise.
    func reconcile(running: RunningSession?, projectName: String?, taskTitle: String?, now: Date) async {
        let all = Activity<StintActivityAttributes>.activities
        let plan = Self.plan(existing: all.map { (id: $0.id, sessionID: $0.attributes.sessionID) },
                             runningSessionID: running?.id.uuidString)
        for a in all where plan.end.contains(a.id) {
            await a.end(ActivityContent(state: .ended(taskTitle: a.content.state.taskTitle), staleDate: nil),
                        dismissalPolicy: .default)
        }
        guard let running else { return }
        let state = LiveSessionState.make(remainingSec: running.remainingSec(at: now), onBreak: running.onBreak,
                                          offTask: running.offTask, taskTitle: taskTitle, now: now)
        if plan.start {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attrs = StintActivityAttributes(sessionID: running.id.uuidString, projectName: projectName ?? "Stint",
                                                plannedMin: running.plannedMin)
            do {
                let a = try Activity.request(attributes: attrs, content: ActivityContent(state: state, staleDate: nil), pushType: .token)
                watch(a)
            } catch {
                print("Live Activity request failed: \(error.localizedDescription)")
            }
        } else if let a = all.first(where: { $0.attributes.sessionID == running.id.uuidString && !plan.end.contains($0.id) }),
                  a.content.state.differs(from: state) {
            await a.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// Pure: keep the first activity for the running session, end every other one, start one if none is kept.
    nonisolated static func plan(existing: [(id: String, sessionID: String)], runningSessionID: String?) -> (start: Bool, end: Set<String>) {
        var end = Set<String>()
        var kept = false
        for e in existing {
            if e.sessionID == runningSessionID && !kept { kept = true } else { end.insert(e.id) }
        }
        return (runningSessionID != nil && !kept, end)
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
```

  Swift 6:
  - The `for await` loops run inside `Task {}` in a `@MainActor` class, so they stay on the main actor. That is fine.
  - If the compiler reports that `Activity` isn't Sendable when it crosses into a `Task`, capture only `activity.id` and look the activity up again in `Activity<StintActivityAttributes>.activities` inside the task.

- [ ] **Step 5: PhoneSync wiring** in `iOS/PhoneSync.swift`.
  - Add `import ActivityKit` if the file needs it.
  - Add the following properties and methods:

```swift
    @ObservationIgnored let live = LiveActivities()
    static let deviceIDKey = "deviceID"

    /// This phone's stable `device.id`.
    private var deviceID: UUID {
        if let s = defaults.string(forKey: Self.deviceIDKey), let id = UUID(uuidString: s) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: Self.deviceIDKey); return id
    }

    private func saveDevice(_ t: LiveActivities.Tokens) async {
        guard let engine, let userID, t.pushToStart != nil || t.activity != nil else { return }
        let row = DeviceRow(id: deviceID, userID: userID, updatedAt: .now, platform: "ios",
                            pushToStartToken: t.pushToStart, activityToken: t.activity, activitySessionID: t.activitySessionID)
        do { try await engine.saveDevice(row) }
        catch { Self.log.error("device: \(error.localizedDescription, privacy: .public)") }
    }

    private func reconcileLive() async {
        let run = running
        var project: Project?
        if let pid = run?.projectID {
            project = (try? ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == pid })))?.first
        }
        let task = run?.firstTaskID.flatMap { id in project?.tasks.first { $0.id == id } }
        await live.reconcile(running: run, projectName: project?.name, taskTitle: task?.title, now: .now)
    }
```

  - In `applyActive(_:)`, inside the `active` branch (where realtime starts), add these lines before `startRealtime`:
    ```swift
    live.onTokens = { [weak self] t in Task { await self?.saveDevice(t) } }
    live.startObserving()
    await saveDevice(live.tokens) // a token that arrived before sign-in
    ```
  - In `refresh()`, right after `publish()` inside the `do` block, add `await reconcileLive()`.

- [ ] **Step 6: `project.yml`.**
  - StintPhone → `info.properties`: add `NSSupportsLiveActivities: true`.
  - StintPhone → `entitlements.properties`: add `aps-environment: development`. The user approved this capability for App ID `dev.stint.ios`.
  - StintWidgets → `sources`: add `- SharedUI/StintActivity.swift`.
  - StintMac → `sources` → the SharedUI `excludes`: add `StintActivity.swift`.
  - Run `xcodegen generate`.

- [ ] **Step 7: Build and test (simulator).**

```bash
xcodegen generate
xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /private/tmp/claude-501/dd-ios test 2>&1 | grep -E 'error:|Test run with|\*\* '
```

  Expected: `TEST SUCCEEDED`, with 17 tests (14 earlier + 3 new). Simulator builds need no provisioning for `aps-environment`.

- [ ] **Step 8: Commit.**

```bash
git add SharedUI/StintActivity.swift Widgets/LiveSessionWidget.swift Widgets/StintWidgets.swift iOS/LiveActivities.swift \
  iOS/PhoneSync.swift iOSTests/LiveActivityTests.swift project.yml iOS/Info.plist iOS/Stint.entitlements
git commit -m "feat(ios): Live Activity with push tokens and foreground reconcile"
```

---

### Task 4: Mac sends Live Activity pushes

**Files:**
- Modify: `Mac/App/AppState.swift`, adding the `onLive` hook fired from `start`, `run` and `finish`
- Modify: `Mac/App/SyncCoordinator.swift`, adding `sendLive` and serializing the calls
- Create: `MacTests/LivePushTests.swift`

**Interfaces:**
- Consumes from Task 2:
  - `LivePush`, `LiveSessionInfo`, `LiveSessionState.make` / `.ended` / `differs(from:)`;
  - `SyncEngine.pushActivity(_:)`.
- Consumes existing `AppState` state:
  - `engine: SessionEngine?`, with `remainingSec(at:)`, `onBreak` and `isOffTask`;
  - `record: SessionRecord?` (its `id` is the session id);
  - `project: Project?`;
  - `firstTask: TaskItem?`.
- Produces: `AppState.onLive: ((LivePush) -> Void)?`.

- [ ] **Step 1: Write the failing test** `MacTests/LivePushTests.swift`:

```swift
import Foundation
import Testing
import SwiftData
import Core
import StintData
@testable import Stint

@MainActor @Suite struct LivePushTests {
    @Test func startBreakResumeEndPushInOrder() throws {
        let c = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let p = Project(name: "Northwind"); c.mainContext.insert(p); try c.mainContext.save()
        let app = AppState(context: c.mainContext)
        var got: [LivePush] = []
        app.onLive = { got.append($0) }

        app.start(project: p, plannedMin: 25, firstTask: nil)
        let first = try #require(got.first)
        #expect(first.event == .start)
        #expect(first.attributes == LiveSessionInfo(sessionID: first.sessionID.uuidString, projectName: "Northwind", plannedMin: 25))

        app.takeBreak()
        let onBreak = try #require(got.last)
        #expect(onBreak.event == .update && onBreak.contentState.status == .onBreak && onBreak.contentState.endsAt == nil)

        app.resume()
        let back = try #require(got.last)
        #expect(back.event == .update && back.contentState.status != .onBreak && back.contentState.endsAt != nil)

        app.endEarly(reason: "test")
        let end = try #require(got.last)
        #expect(end.event == .end && end.contentState.status == .ended)
        #expect(got.allSatisfy { $0.sessionID == first.sessionID })
        #expect(got.filter { $0.event == .start }.count == 1)
        _ = c
    }
}
```

  The frontmost app during the test (Xcode or Terminal) may count as off task, which adds an extra `.update`. So the test checks `first` and `last`, not exact counts of updates.

- [ ] **Step 2: Run it to see it fail.** Run `xcodebuild -scheme StintMac -derivedDataPath /private/tmp/claude-501/dd2 PRODUCT_BUNDLE_IDENTIFIER=dev.stint.mac.alt test 2>&1 | grep -E 'error:|Test run with|\*\* '`. Expected: a compile error, `value of type 'AppState' has no member 'onLive'`.

- [ ] **Step 3: AppState hook** in `Mac/App/AppState.swift`:
  - Next to `onCheckpoint` and `onSessionClosed`, add:
    ```swift
        /// Live Activity hook (plan 7): .start once, .update when what the phone shows changes, .end on close.
        @ObservationIgnored var onLive: ((LivePush) -> Void)?
        @ObservationIgnored private var lastLive: LiveSessionState?

        private func liveState(at now: Date) -> LiveSessionState? {
            guard let e = engine else { return nil }
            return .make(remainingSec: e.remainingSec(at: now), onBreak: e.onBreak, offTask: e.isOffTask,
                         taskTitle: firstTask?.title, now: now)
        }
    ```
  - In `start(project:plannedMin:firstTask:)`, put this right after the line `engine = e; now = started; ...`, before the timer and the monitor are created. The monitor's first `reportCurrent()` must compare against `lastLive`.
    ```swift
            if let r = record, let s = liveState(at: started) {
                lastLive = s
                onLive?(LivePush(event: .start, sessionID: r.id,
                                 attributes: LiveSessionInfo(sessionID: r.id.uuidString, projectName: project.name, plannedMin: plannedMin),
                                 contentState: s))
            }
    ```
  - At the end of `run(stateChange:_:)`, after the existing `checkpoint()` line:
    ```swift
            if let s = liveState(at: .now), let r = record, let last = lastLive, s.differs(from: last) {
                lastLive = s
                onLive?(LivePush(event: .update, sessionID: r.id, attributes: nil, contentState: s))
            }
    ```
  - In `finish(early:reason:)`, right after the `Ledger.close` do/catch and before `engine = nil; record = nil; ...`:
    ```swift
            onLive?(LivePush(event: .end, sessionID: r.id, attributes: nil, contentState: .ended(taskTitle: firstTask?.title)))
            lastLive = nil
    ```
  - Add `import Core` if `LivePush` doesn't resolve.

- [ ] **Step 4: SyncCoordinator** in `Mac/App/SyncCoordinator.swift`:
  - Add the property `@ObservationIgnored private var livePushes: Task<Void, Never>?`.
  - In `init`, after `app.onSessionClosed = ...`, add:
    ```swift
            app.onLive = { [weak self] in self?.sendLive($0) }
    ```
  - Add this method in a `// MARK: live activity` section:
    ```swift
        /// In order, one at a time: an update must never overtake its start. Failures (503 = no APNs key yet) are logged only;
        /// the phone's own foreground reconcile still shows the session.
        private func sendLive(_ push: LivePush) {
            guard let engine, userID != nil else { return }
            let previous = livePushes
            livePushes = Task {
                await previous?.value
                do { try await engine.pushActivity(push) }
                catch { Self.log.notice("push-activity \(push.event.rawValue, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            }
        }
    ```
  - In `signOut()`, add `livePushes?.cancel(); livePushes = nil` next to the other cancels.

- [ ] **Step 5: Build and test both apps.**

```bash
xcodebuild -scheme StintMac -derivedDataPath /private/tmp/claude-501/dd2 PRODUCT_BUNDLE_IDENTIFIER=dev.stint.mac.alt test 2>&1 | grep -E 'error:|Test run with|\*\* '
rm -rf /private/tmp/claude-501/dd2
xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /private/tmp/claude-501/dd-ios test 2>&1 | grep -E 'error:|Test run with|\*\* '
cd Shared && swift test --disable-sandbox 2>&1 | tail -3
```

  Expected:
  - Mac: 11 tests.
  - iOS: 17 tests.
  - SwiftPM: everything passes.
  - Keep `dd-ios` for the controller's manual check.

- [ ] **Step 6: Commit.**

```bash
git add Mac/App/AppState.swift Mac/App/SyncCoordinator.swift MacTests/LivePushTests.swift
git commit -m "feat(mac): push Live Activity start, updates and end"
```

- [ ] **Step 7: Manual check (controller).**
  1. **Foreground fallback (simulator, signed-in test account):**
     - Insert a running session for that account's Northwind project with `psql` in the local DB container.
     - The open app shows the session, and the Live Activity appears. Lock the simulator to see the lock screen view: project, countdown, "Focused".
  2. **Update:** insert a `break_start` `session_event` for that session. The activity shows "On break" with a static remaining time.
  3. **End:** set `ended_at` on that session. The activity shows "Session ended" and is then dismissed.
  4. **Mac call:** with the Mac app signed in, start and end a session.
     - The edge runtime logs show `push-activity` calls.
     - Without an APNs key they return 503, which the Mac logs as a notice.
  5. **Device token row:** `select platform, push_to_start_token is not null, activity_token is not null from public.device` shows the simulator's row.
  6. **Capability:**
     - Run one device build so automatic signing adds Push Notifications to `dev.stint.ios` (the user approved this): `xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'generic/platform=iOS' -allowProvisioningUpdates -derivedDataPath /private/tmp/claude-501/dd-dev build`.
     - Then run `rm -rf /private/tmp/claude-501/dd-dev`.
  7. **With a key** (after the user adds the `APNS_*` values and restarts the stack): starting a session on the Mac while the phone app is closed shows the Live Activity.

---

## Done when

- `deno test` passes in `push-activity` (5 tests) and `parse-tasks` (6 tests), and `deno check index.ts` is clean for both.
- `supabase test db` passes after `supabase migration up`.
- `cd Shared && swift test --disable-sandbox` passes, including `LiveSessionTests` and `DeviceRowTests`.
- The Mac (11) and iPhone (17) `xcodebuild … test` runs pass.
- Manual checks 1–6 pass. Check 7 runs once the user adds the APNs key.
