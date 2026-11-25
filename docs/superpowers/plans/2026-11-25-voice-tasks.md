# Voice Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Speak (or type) a to-do list on iPhone or Mac, have Claude split it into tasks with projects and estimates, confirm, and save them.

**Architecture:**
- A Supabase Edge Function `parse-tasks` calls Claude (`claude-haiku-5-5`) with a structured-output schema. It cleans the result: drops empty titles, nulls unknown projects and bad estimates.
- The function's pure logic (`parse.ts`) is Deno-tested with a stubbed Claude caller.
- Swift side:
  - `Core.VoiceTasks` holds the pure draft rules.
  - `StintData` holds the network call (`SyncEngine.parseTasks`) and the save (`VoiceSave`).
  - `SharedUI` holds on-device speech capture (`SpeechCapture`) and one `DictateView` used by both the iPhone Dictate tab and the Mac "Dictate tasks" sheet.
- With no `ANTHROPIC_API_KEY` set, the function returns 503 and the app falls back to one editable task (spec §6.8 failure path). The user adds the key later.

**Tech Stack:** Deno 2 + `npm:@anthropic-ai/sdk` + `npm:zod` (edge function), Swift 6 / SwiftUI / SwiftData, `Speech` + `AVFoundation`, supabase-swift 2.55 `functions.invoke`.

**Spec:** `docs/superpowers/specs/2026-11-24-freelance-focus-app-design.md` (§3 Speech/AI parsing rows, §6.8 Tasks and voice, §6.9 Dictate tab, §7 Microphone + Speech, §8 Edge functions testing).

## Global Constraints

- Speech: `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`.
- AI parsing: Claude via an Edge Function (key stays server-side). Model: `claude-haiku-5-5`.
- Function output per task: `{title, project_id|null, estimate_min|null, estimate_guessed}`. Validate against the schema. Drop items with empty titles.
- Confirm screen:
  - Each task is checked by default. Title, project and estimate are editable.
  - Guessed estimates are labelled "guessed".
  - An unmatched project shows "Choose project", which is required before saving.
  - "Add N tasks" saves the checked items.
- Failures:
  - Speech permission denied → a typed text field instead, same flow.
  - Network/AI failure → the transcript becomes one editable task, with an error line.
  - Transcript > 4,000 chars → rejected before sending.
- iPhone tabs: Today, Tasks, Dictate (centre), Week, Rewards. Mac gets a "Dictate tasks" button using the same flow.
- Mac permission: Microphone + Speech, used for Mac dictation. If denied, fall back to typed input.
- Tasks created by voice have `source = "voice"`. The phone may create `TaskItem`s (plan 5 rule).
- Swift 6 strict concurrency.
- SwiftPM tests run with `cd Shared && swift test --disable-sandbox`. The flag is mandatory.

**Rulings baked into this plan (spec deviations):**
- **Structured output via `output_config.format` instead of a tool schema.** It gives the same schema guarantee, is the SDK's documented path (`messages.parse` + `zodOutputFormat`), and avoids forced `tool_choice`.
- **The function requires a signed-in user.** It rejects JWTs whose `role` is not `authenticated`, so the public anon key can't spend Claude credit.
- **Transcript length is counted in Unicode scalars on both sides** (Swift `unicodeScalars.count`, JS `[...s].length`), so client and server agree on 4,000.

---

### Task 1: `parse-tasks` Edge Function

**Files:**
- Create: `supabase/functions/parse-tasks/parse.ts`
- Create: `supabase/functions/parse-tasks/claude.ts`
- Create: `supabase/functions/parse-tasks/index.ts`
- Create: `supabase/functions/parse-tasks/parse_test.ts`
- Create (via `deno add`): `supabase/functions/parse-tasks/deno.json`
- Create: `supabase/functions/.env.example`
- Modify: `.gitignore` (add `supabase/functions/.env`)

**Interfaces:**
- Produces an HTTP contract (Task 2 relies on it):
  - Request: `POST /functions/v1/parse-tasks`, JSON body `{"transcript": String, "projects": [{"id": uuid-string, "name": String}]}`, with the user's JWT.
  - `200 {"tasks": [{"title": String, "project_id": uuid-string|null, "estimate_min": Int|null, "estimate_guessed": Bool}]}`.
  - Errors return a JSON `{"error": code}` with these statuses:
    - 400 `empty` / `bad_json`
    - 401 `auth`
    - 405 `method`
    - 413 `too_long`
    - 502 `ai_failed`
    - 503 `ai_unavailable` (no key)

- [ ] **Step 1: Add dependencies.** From the repo root:

```bash
cd supabase/functions/parse-tasks 2>/dev/null || mkdir -p supabase/functions/parse-tasks && cd supabase/functions/parse-tasks
deno add npm:@anthropic-ai/sdk npm:zod jsr:@std/assert
```

This writes `deno.json` with an `imports` map. Supabase's edge runtime reads a per-function `deno.json`.

- [ ] **Step 2: Write the failing test** `supabase/functions/parse-tasks/parse_test.ts`:

```ts
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
```

- [ ] **Step 3: Run it to see it fail.** Run `cd supabase/functions/parse-tasks && deno test`. Expected: FAIL, module `./parse.ts` not found.

- [ ] **Step 4: Implement** `supabase/functions/parse-tasks/parse.ts`:

```ts
export const MAX_TRANSCRIPT = 4000; // Unicode scalars; the apps count the same way
export type Project = { id: string; name: string };
export type ParsedTask = { title: string; project_id: string | null; estimate_min: number | null; estimate_guessed: boolean };
export type Caller = (transcript: string, projects: Project[]) => Promise<unknown>;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

/** The gateway has already verified the JWT; only signed-in users may spend Claude credit. */
function role(req: Request): string | null {
  const token = req.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
  try {
    const b64 = token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(atob(b64 + "=".repeat((4 - b64.length % 4) % 4))).role ?? null;
  } catch { return null; }
}

/** Keeps well-formed tasks: non-empty title, known project or null, whole-minute estimate 1–1440 or null. */
export function clean(raw: unknown, projects: Project[]): ParsedTask[] {
  const items = (raw as { tasks?: unknown } | null)?.tasks;
  if (!Array.isArray(items)) throw new Error("response has no tasks array");
  const known = new Set(projects.map((p) => p.id));
  return items.flatMap((t) => {
    if (typeof t !== "object" || t === null) return [];
    const o = t as Record<string, unknown>;
    const title = typeof o.title === "string" ? o.title.trim().slice(0, 200) : "";
    if (!title) return [];
    const pid = typeof o.project_id === "string" && known.has(o.project_id) ? o.project_id : null;
    const m = o.estimate_min;
    const est = typeof m === "number" && Number.isInteger(m) && m >= 1 && m <= 1440 ? m : null;
    return [{ title, project_id: pid, estimate_min: est, estimate_guessed: est !== null && o.estimate_guessed === true }];
  });
}

export async function handle(req: Request, call: Caller | null): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method" });
  if (role(req) !== "authenticated") return json(401, { error: "auth" });
  let body: { transcript?: unknown; projects?: unknown };
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }
  const transcript = typeof body?.transcript === "string" ? body.transcript.trim() : "";
  if (!transcript) return json(400, { error: "empty" });
  if ([...transcript].length > MAX_TRANSCRIPT) return json(413, { error: "too_long" });
  const projects = (Array.isArray(body.projects) ? body.projects : []).filter(
    (p): p is Project => typeof p?.id === "string" && typeof p?.name === "string",
  ).map(({ id, name }) => ({ id, name }));
  if (!call) return json(503, { error: "ai_unavailable" });
  try {
    return json(200, { tasks: clean(await call(transcript, projects), projects) });
  } catch (e) {
    console.error("parse-tasks:", e instanceof Error ? e.message : e);
    return json(502, { error: "ai_failed" });
  }
}
```

- [ ] **Step 5: Run the tests.** `deno test`. Expected: all 5 tests PASS.

- [ ] **Step 6: Write the Claude caller** `supabase/functions/parse-tasks/claude.ts`. It uses the official SDK's structured outputs, per the claude-api skill. It is not unit-tested, since `handle` takes the caller as a parameter.

```ts
import Anthropic from "@anthropic-ai/sdk";
import { zodOutputFormat } from "@anthropic-ai/sdk/helpers/zod";
import { z } from "zod";
import type { Caller } from "./parse.ts";

const Output = z.object({
  tasks: z.array(z.object({
    title: z.string(),
    project_id: z.string().nullable(),
    estimate_min: z.number().nullable(),
    estimate_guessed: z.boolean(),
  })),
});

const SYSTEM = `You turn a freelancer's spoken to-do list into separate tasks.
- One task per distinct action. Title: short and imperative, in the speaker's own words, under 80 characters. Leave out filler ("um", "I need to").
- project_id: the id of a project from the list only when the speaker clearly refers to it (by name or an obvious short form). Otherwise null. Never invent ids.
- estimate_min: if the speaker states a duration, use it in minutes with estimate_guessed false. Otherwise give a realistic guess in minutes with estimate_guessed true, or null if there's no sensible guess.
- If nothing in the transcript is a task, return an empty list.`;

export function claudeCaller(apiKey: string): Caller {
  const client = new Anthropic({ apiKey, maxRetries: 1, timeout: 25_000 });
  return async (transcript, projects) => {
    const res = await client.messages.parse({
      model: "claude-haiku-5-5",
      max_tokens: 8000,
      system: SYSTEM,
      messages: [{ role: "user", content: `Projects:\n${JSON.stringify(projects)}\n\nTranscript:\n${transcript}` }],
      output_config: { format: zodOutputFormat(Output), effort: "low" },
    });
    if (res.stop_reason !== "end_turn" || !res.parsed_output) throw new Error(`no output (stop_reason ${res.stop_reason})`);
    return res.parsed_output;
  };
}
```

If `deno check claude.ts` reports a type error in the SDK call, fix it from the compiler message. Keep the model, effort and schema unchanged.

- [ ] **Step 7: Entry point** `supabase/functions/parse-tasks/index.ts`:

```ts
import { handle } from "./parse.ts";
import { claudeCaller } from "./claude.ts";

const key = Deno.env.get("ANTHROPIC_API_KEY");
const call = key ? claudeCaller(key) : null; // no key: 503, and the apps fall back to one editable task

Deno.serve((req) => handle(req, call));
```

- [ ] **Step 8: Local secrets file.**
  - Create `supabase/functions/.env.example` with exactly:
    ```
    # Copy to supabase/functions/.env (gitignored) and fill in. Then: supabase stop && supabase start
    ANTHROPIC_API_KEY=
    ```
  - Append `supabase/functions/.env` to `.gitignore`.
  - Never create the real `.env` and never handle a key. The user adds it.

- [ ] **Step 9: Check types and serve locally.**

```bash
cd supabase/functions/parse-tasks && deno check index.ts && deno test && cd ../../..
supabase stop && supabase start   # picks up the new function; data persists
ANON=$(supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"/\1/p')
curl -s -w ' %{http_code}\n' -X POST http://127.0.0.1:54321/functions/v1/parse-tasks \
  -H "Authorization: Bearer $ANON" -H 'Content-Type: application/json' -d '{"transcript":"x","projects":[]}'
```

Expected: `{"error":"auth"} 401`, because the anon key's role is `anon`. That proves the function is deployed and the auth gate holds.

If realtime logs loop `ReplicationSlotBeingUsed` after the restart, run `supabase stop && supabase start` again.

- [ ] **Step 10: Commit.**

```bash
git add supabase/functions/parse-tasks supabase/functions/.env.example .gitignore
git commit -m "feat(fn): parse-tasks edge function with Claude structured output"
```

---

### Task 2: Draft rules, the network call and saving

**Files:**
- Create: `Shared/Sources/Core/VoiceTasks.swift`
- Create: `Shared/Tests/CoreTests/VoiceTasksTests.swift`
- Create: `Shared/Sources/StintData/Sync/ParseTasks.swift`
- Create: `Shared/Sources/StintData/VoiceSave.swift`
- Create: `Shared/Tests/StintDataTests/VoiceSaveTests.swift`
- Modify: `Shared/Sources/StintData/Sync/SyncEngine.swift:10`, changing `private let client` to `let client` so the extension in `ParseTasks.swift` can use it.

**Interfaces:**
- Consumes: Task 1's HTTP contract.
- Produces (Task 3 relies on these exact names):
  - `Core.ParsedTask`:
    - `public struct ParsedTask: Codable, Equatable, Sendable`
    - fields `title: String`, `projectID: UUID?`, `estimateMin: Int?`, `estimateGuessed: Bool`
    - wire keys are snake_case
  - `Core.DraftTask`:
    - `public struct DraftTask: Identifiable, Equatable, Sendable`
    - `id: UUID`, and `var` fields `title`, `projectID: UUID?`, `estimateMin: Int?`, `estimateGuessed: Bool`, `checked: Bool`
  - `Core.VoiceTasks`:
    - `maxTranscript = 4000`
    - `enum TranscriptError: Error, Equatable { case empty, tooLong }`
    - `static func check(_ s: String) -> Result<String, TranscriptError>`
    - `static func drafts(_ parsed: [ParsedTask], projectIDs: Set<UUID>) -> [DraftTask]`
    - `static func fallback(_ transcript: String) -> [DraftTask]`
    - `static func canSave(_ drafts: [DraftTask]) -> Bool`
    - `static func checkedCount(_ drafts: [DraftTask]) -> Int`
  - `StintData.SyncEngine.parseTasks(transcript: String, projects: [Project]) async throws -> [ParsedTask]`, which is `@MainActor`.
  - `StintData.VoiceSave.save(_ drafts: [DraftTask], projects: [Project], in ctx: ModelContext) throws -> Int`, which is `@MainActor` and returns the number saved.

- [ ] **Step 1: Write the failing Core test** `Shared/Tests/CoreTests/VoiceTasksTests.swift`:

```swift
import Testing
import Foundation
@testable import Core

@Suite struct VoiceTasksTests {
    let a = UUID(), b = UUID()

    @Test func checkTrimsAndLimitsByScalars() {
        #expect(VoiceTasks.check("  call bank \n") == .success("call bank"))
        #expect(VoiceTasks.check("   ") == .failure(.empty))
        #expect(VoiceTasks.check(String(repeating: "é", count: 4000)) == .success(String(repeating: "é", count: 4000)))
        #expect(VoiceTasks.check(String(repeating: "a", count: 4001)) == .failure(.tooLong))
    }

    @Test func decodesWireShape() throws {
        let json = #"[{"title":"Send invoice","project_id":"\#(a.uuidString)","estimate_min":15,"estimate_guessed":false},{"title":"Call bank","project_id":null,"estimate_min":null,"estimate_guessed":false}]"#
        let p = try JSONDecoder().decode([ParsedTask].self, from: Data(json.utf8))
        #expect(p == [ParsedTask(title: "Send invoice", projectID: a, estimateMin: 15, estimateGuessed: false),
                      ParsedTask(title: "Call bank", projectID: nil, estimateMin: nil, estimateGuessed: false)])
    }

    @Test func draftsAreCheckedAndDropUnknownProjectsAndEmptyTitles() {
        let d = VoiceTasks.drafts([
            ParsedTask(title: "A", projectID: a, estimateMin: 30, estimateGuessed: true),
            ParsedTask(title: " ", projectID: a, estimateMin: nil, estimateGuessed: false),
            ParsedTask(title: "B", projectID: UUID(), estimateMin: nil, estimateGuessed: false),
        ], projectIDs: [a, b])
        #expect(d.map(\.title) == ["A", "B"])
        #expect(d.map(\.projectID) == [a, nil])
        #expect(d.allSatisfy(\.checked))
        #expect(d[0].estimateMin == 30 && d[0].estimateGuessed)
    }

    @Test func fallbackIsOneUncheckedProjectTask() {
        let d = VoiceTasks.fallback("  email Sam about the logo  ")
        #expect(d.count == 1)
        #expect(d[0].title == "email Sam about the logo" && d[0].projectID == nil && d[0].checked && d[0].estimateMin == nil)
        #expect(VoiceTasks.fallback(String(repeating: "x", count: 500))[0].title.count == 200)
    }

    @Test func canSaveNeedsACheckedTaskAndProjectsOnEveryCheckedTask() {
        var d = VoiceTasks.drafts([ParsedTask(title: "A", projectID: a, estimateMin: nil, estimateGuessed: false),
                                   ParsedTask(title: "B", projectID: nil, estimateMin: nil, estimateGuessed: false)], projectIDs: [a])
        #expect(!VoiceTasks.canSave(d))              // B has no project
        d[1].checked = false
        #expect(VoiceTasks.canSave(d) && VoiceTasks.checkedCount(d) == 1)
        d[0].title = "  "
        #expect(!VoiceTasks.canSave(d))              // empty title
        d[0].checked = false
        #expect(!VoiceTasks.canSave(d))              // nothing checked
    }
}
```

- [ ] **Step 2: Run it to see it fail.** `cd Shared && swift test --disable-sandbox --filter VoiceTasksTests`. Expected: FAIL, `cannot find 'VoiceTasks' in scope`.

- [ ] **Step 3: Implement** `Shared/Sources/Core/VoiceTasks.swift`:

```swift
import Foundation

/// One task as `parse-tasks` returns it.
public struct ParsedTask: Codable, Equatable, Sendable {
    public var title: String
    public var projectID: UUID?
    public var estimateMin: Int?
    public var estimateGuessed: Bool
    public init(title: String, projectID: UUID?, estimateMin: Int?, estimateGuessed: Bool) {
        self.title = title; self.projectID = projectID; self.estimateMin = estimateMin; self.estimateGuessed = estimateGuessed
    }
    enum CodingKeys: String, CodingKey {
        case title, projectID = "project_id", estimateMin = "estimate_min", estimateGuessed = "estimate_guessed"
    }
}

/// A row on the confirm screen.
public struct DraftTask: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var projectID: UUID?
    public var estimateMin: Int?
    public var estimateGuessed: Bool
    public var checked: Bool
    public init(title: String, projectID: UUID?, estimateMin: Int?, estimateGuessed: Bool, checked: Bool = true) {
        id = UUID(); self.title = title; self.projectID = projectID
        self.estimateMin = estimateMin; self.estimateGuessed = estimateGuessed; self.checked = checked
    }
}

/// Spec §6.8: voice → confirm → save.
public enum VoiceTasks {
    public static let maxTranscript = 4000 // Unicode scalars; parse-tasks counts the same way
    public enum TranscriptError: Error, Equatable { case empty, tooLong }

    public static func check(_ s: String) -> Result<String, TranscriptError> {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .failure(.empty) }
        if t.unicodeScalars.count > maxTranscript { return .failure(.tooLong) }
        return .success(t)
    }

    /// Projects the phone or Mac doesn't know become "Choose project".
    public static func drafts(_ parsed: [ParsedTask], projectIDs: Set<UUID>) -> [DraftTask] {
        parsed.compactMap { p in
            let title = p.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return DraftTask(title: title, projectID: p.projectID.flatMap { projectIDs.contains($0) ? $0 : nil },
                             estimateMin: p.estimateMin, estimateGuessed: p.estimateMin != nil && p.estimateGuessed)
        }
    }

    /// Network/AI failure: the transcript becomes one editable task.
    public static func fallback(_ transcript: String) -> [DraftTask] {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return [DraftTask(title: String(t.prefix(200)), projectID: nil, estimateMin: nil, estimateGuessed: false)]
    }

    public static func checkedCount(_ drafts: [DraftTask]) -> Int { drafts.filter(\.checked).count }

    public static func canSave(_ drafts: [DraftTask]) -> Bool {
        let checked = drafts.filter(\.checked)
        return !checked.isEmpty && checked.allSatisfy {
            $0.projectID != nil && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
```

- [ ] **Step 4: Run the Core tests.** `cd Shared && swift test --disable-sandbox --filter VoiceTasksTests`. Expected: 5 tests PASS.

- [ ] **Step 5: Write the failing StintData test** `Shared/Tests/StintDataTests/VoiceSaveTests.swift`:

```swift
import Testing
import Foundation
import SwiftData
import Core
@testable import StintData

@MainActor @Suite struct VoiceSaveTests {
    @Test func savesCheckedDraftsAsVoiceTasksAtTheEnd() throws {
        let container = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        let p = Project(name: "Northwind"); ctx.insert(p)
        let old = TaskItem(title: "Old", sort: 4); ctx.insert(old); old.project = p
        try ctx.save()

        var drafts = [
            DraftTask(title: " Send invoice ", projectID: p.id, estimateMin: 15, estimateGuessed: true),
            DraftTask(title: "Skip me", projectID: p.id, estimateMin: nil, estimateGuessed: false),
            DraftTask(title: "Call bank", projectID: p.id, estimateMin: nil, estimateGuessed: true),
        ]
        drafts[1].checked = false
        #expect(try VoiceSave.save(drafts, projects: [p], in: ctx) == 2)

        let new = p.tasks.filter { $0.source == "voice" }.sorted { $0.sort < $1.sort }
        #expect(new.map(\.title) == ["Send invoice", "Call bank"])
        #expect(new.map(\.sort) == [5, 6])
        #expect(new[0].estimateMin == 15 && new[0].estimateGuessed)
        #expect(new[1].estimateMin == nil && !new[1].estimateGuessed) // no estimate → not "guessed"
        #expect(new.allSatisfy { $0.syncedAt == nil })               // dirty, so it syncs
        _ = container
    }

    @Test func skipsDraftsWhoseProjectIsGone() throws {
        let container = try ModelContainer(for: Schema(StintSchema.models), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(container)
        #expect(try VoiceSave.save([DraftTask(title: "A", projectID: UUID(), estimateMin: nil, estimateGuessed: false)],
                                   projects: [], in: ctx) == 0)
        _ = container
    }
}
```

- [ ] **Step 6: Run it to see it fail.** `cd Shared && swift test --disable-sandbox --filter VoiceSaveTests`. Expected: FAIL, `cannot find 'VoiceSave' in scope`.

- [ ] **Step 7: Implement** `Shared/Sources/StintData/VoiceSave.swift`:

```swift
import Foundation
import SwiftData
import Core

@MainActor
public enum VoiceSave {
    /// Saves checked drafts as `source = "voice"` tasks at the end of each project's list. Returns how many were saved.
    public static func save(_ drafts: [DraftTask], projects: [Project], in ctx: ModelContext) throws -> Int {
        let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [UUID: Int] = [:]
        var saved = 0
        for d in drafts where d.checked {
            let title = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, let pid = d.projectID, let p = byID[pid] else { continue }
            let sort = next[pid] ?? ((p.tasks.map(\.sort).max() ?? -1) + 1)
            next[pid] = sort + 1
            let t = TaskItem(title: title, estimateMin: d.estimateMin, estimateGuessed: d.estimateMin != nil && d.estimateGuessed,
                             source: "voice", sort: sort)
            ctx.insert(t)
            t.project = p
            saved += 1
        }
        try ctx.save()
        return saved
    }
}
```

- [ ] **Step 8: The network call.**
  - In `Shared/Sources/StintData/Sync/SyncEngine.swift`, change `private let client: SupabaseClient` to `let client: SupabaseClient`.
  - Create `Shared/Sources/StintData/Sync/ParseTasks.swift`:

```swift
import Foundation
import Supabase
import Core

private struct ParseRequest: Encodable {
    struct P: Encodable { let id: UUID; let name: String }
    let transcript: String
    let projects: [P]
}
private struct ParseResponse: Decodable { let tasks: [ParsedTask] }

extension SyncEngine {
    /// Calls the `parse-tasks` edge function with the signed-in user's token. Throws on any non-2xx (503 = no AI key yet).
    public func parseTasks(transcript: String, projects: [Project]) async throws -> [ParsedTask] {
        let body = ParseRequest(transcript: transcript, projects: projects.map { .init(id: $0.id, name: $0.name) })
        let r: ParseResponse = try await client.functions.invoke("parse-tasks", options: FunctionInvokeOptions(body: body),
                                                                 decoder: JSONDecoder())
        return r.tasks
    }
}
```

`JSONEncoder` writes `UUID` as an uppercase string. The function compares project ids as strings, so the projects sent and the ids returned use the same spelling. Postgres would treat case as equal, but this match is a JS `Set` lookup. Keep `.uuidString` from the encoder unchanged. Don't lowercase.

- [ ] **Step 9: Run all SwiftPM tests.** `cd Shared && swift test --disable-sandbox`. Expected: all pass, with 2 new suites. The integration suite skips unless `STINT_SUPABASE_URL` is set.

- [ ] **Step 10: Commit.**

```bash
git add Shared/Sources/Core/VoiceTasks.swift Shared/Tests/CoreTests/VoiceTasksTests.swift Shared/Sources/StintData/VoiceSave.swift \
  Shared/Tests/StintDataTests/VoiceSaveTests.swift Shared/Sources/StintData/Sync/ParseTasks.swift Shared/Sources/StintData/Sync/SyncEngine.swift
git commit -m "feat(voice): draft rules, parse-tasks call and voice task save"
```

---

### Task 3: Speech capture, Dictate screen, iPhone tab and Mac button

**Files:**
- Create: `SharedUI/SpeechCapture.swift`
- Create: `SharedUI/DictateView.swift`
- Modify: `iOS/UI/RootView.swift` (Dictate tab in the centre)
- Modify: `iOS/PhoneSync.swift` (`parseTasks`)
- Modify: `Mac/App/SyncCoordinator.swift` (`parseTasks`)
- Modify: `Mac/UI/TodayView.swift` ("Dictate tasks" button and sheet)
- Modify: `project.yml`:
  - usage strings on both apps;
  - the Mac audio-input entitlement;
  - `Speech.framework` is auto-linked, so no change is needed for it.

**Interfaces:**
- Consumes from Task 2:
  - `VoiceTasks`, `DraftTask`, `ParsedTask`;
  - `SyncEngine.parseTasks(transcript:projects:)`;
  - `VoiceSave.save(_:projects:in:)`.
- Produces:
  - `struct DictateView: View`, with `init(parse: @escaping @MainActor (String, [Project]) async throws -> [ParsedTask], onSaved: @escaping @MainActor (Int) -> Void)`;
  - `PhoneSync.parseTasks(_ transcript: String, projects: [Project]) async throws -> [ParsedTask]`;
  - `SyncCoordinator.parseTasks(_ transcript: String, projects: [Project]) async throws -> [ParsedTask]`.

- [ ] **Step 1: Usage strings and entitlement** in `project.yml`:
  - Under `StintMac` → `info.properties`, and under `StintPhone` → `info.properties`, add:
    ```yaml
            NSMicrophoneUsageDescription: "Stint listens while you dictate tasks. Audio stays on this device."
            NSSpeechRecognitionUsageDescription: "Stint turns your dictation into text on this device, then into a task list."
    ```
  - Under `StintMac` → `entitlements.properties`, add `com.apple.security.device.audio-input: true`. Hardened runtime blocks the microphone without it.

- [ ] **Step 2: Speech capture** `SharedUI/SpeechCapture.swift`.
  - Callbacks from the audio tap and the recogniser run off the main thread.
  - Build them in `nonisolated` static functions. A closure written inside a `@MainActor` method inherits main-actor isolation, and Swift 6 traps when it runs elsewhere.

```swift
import Foundation
import Speech
import AVFoundation
import Observation

/// On-device dictation. `unavailable` means: show the typed field instead (spec §6.8).
@MainActor @Observable
final class SpeechCapture {
    enum Mode: Equatable { case idle, recording, unavailable(String) }
    var mode: Mode = .idle
    var transcript = ""

    @ObservationIgnored private let audio = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() async {
        guard mode != .recording else { return }
        guard await Self.speechAllowed(), await Self.micAllowed() else {
            mode = .unavailable("Dictation is off for Stint. Type your tasks instead, or allow Microphone and Speech Recognition in Settings.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            mode = .unavailable("On-device dictation isn't available here. Type your tasks instead.")
            return
        }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: .duckOthers)
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true
        req.shouldReportPartialResults = true
        let input = audio.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(req))
        do { audio.prepare(); try audio.start() } catch {
            input.removeTap(onBus: 0)
            mode = .unavailable("Couldn't use the microphone. Type your tasks instead.")
            return
        }
        let base = transcript.isEmpty ? "" : transcript + " " // keep what was there before this take
        request = req
        mode = .recording
        task = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, done in
            guard let self else { return }
            if let text { self.transcript = base + text }
            if done { self.stop() }
        })
    }

    func stop() {
        guard mode == .recording else { return }
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        request = nil; task = nil
        mode = .idle
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: off-main callbacks

    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in req.append(buffer) }
    }

    nonisolated private static func handler(_ update: @escaping @MainActor (String?, Bool) -> Void)
        -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in update(text, done) }
        }
    }

    nonisolated private static func speechAllowed() async -> Bool {
        await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
    }

    nonisolated private static func micAllowed() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
```

If the compiler flags a `Sendable` capture, wrap the captured value in a `nonisolated(unsafe) let` local. Don't move a callback back onto the main actor.

- [ ] **Step 3: Dictate screen** `SharedUI/DictateView.swift`:

```swift
import SwiftUI
import SwiftData
import Core
import StintData

/// Spec §6.8: record or type → Make tasks → confirm → "Add N tasks".
struct DictateView: View {
    let parse: @MainActor (String, [Project]) async throws -> [ParsedTask]
    let onSaved: @MainActor (Int) -> Void

    @Environment(\.modelContext) private var ctx
    @Query(filter: #Predicate<Project> { $0.archivedAt == nil }, sort: \Project.name) private var projects: [Project]
    @State private var speech = SpeechCapture()
    @State private var drafts: [DraftTask]?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        Group {
            if let drafts { confirm(drafts) } else { capture }
        }
        .onDisappear { speech.stop() }
    }

    // MARK: capture

    private var capture: some View {
        @Bindable var speech = speech
        return VStack(alignment: .leading, spacing: 12) {
            Text("Say what you need to do. Name the project if you can.").foregroundStyle(.secondary)
            TextEditor(text: $speech.transcript)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(speech.mode == .recording)
            if case let .unavailable(why) = speech.mode { Text(why).font(.footnote).foregroundStyle(Palette.warn) }
            if let message { Text(message).font(.footnote).foregroundStyle(Palette.warn) }
            HStack {
                if speech.mode == .recording {
                    Button("Stop", systemImage: "stop.circle.fill") { speech.stop() }
                } else if !isUnavailable {
                    Button("Record", systemImage: "mic.circle.fill") { Task { await speech.start() } }
                }
                Spacer()
                Button("Make tasks") { Task { await makeTasks() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || speech.mode == .recording || speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if working { ProgressView("Sorting your tasks…") }
        }
        .padding()
    }

    private var isUnavailable: Bool { if case .unavailable = speech.mode { true } else { false } }

    private func makeTasks() async {
        message = nil
        switch VoiceTasks.check(speech.transcript) {
        case .failure(.tooLong):
            message = "That's over \(VoiceTasks.maxTranscript) characters. Shorten it and try again."
        case .failure(.empty):
            break
        case let .success(text):
            working = true; defer { working = false }
            do {
                let parsed = try await parse(text, projects)
                let d = VoiceTasks.drafts(parsed, projectIDs: Set(projects.map(\.id)))
                if d.isEmpty { drafts = VoiceTasks.fallback(text); message = "No separate tasks found. Edit the one below." }
                else { drafts = d }
            } catch {
                drafts = VoiceTasks.fallback(text)
                message = "Couldn't sort this automatically. Edit the task below."
            }
        }
    }

    // MARK: confirm

    private func confirm(_ current: [DraftTask]) -> some View {
        let binding = Binding(get: { drafts ?? [] }, set: { drafts = $0 })
        let n = VoiceTasks.checkedCount(current)
        return VStack(spacing: 0) {
            if let message { Text(message).font(.footnote).foregroundStyle(Palette.warn).padding(.top) }
            List {
                ForEach(binding) { $d in row($d) }
            }
            HStack {
                Button("Back") { drafts = nil; message = nil }
                Spacer()
                Button(n == 1 ? "Add 1 task" : "Add \(n) tasks") { save(current) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!VoiceTasks.canSave(current))
            }
            .padding()
        }
    }

    private func row(_ d: Binding<DraftTask>) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: d.checked).labelsHidden()
            VStack(alignment: .leading, spacing: 6) {
                TextField("Task", text: d.title)
                Picker("Project", selection: d.projectID) {
                    Text("Choose project").tag(UUID?.none)
                    ForEach(projects) { Text($0.name).tag(Optional($0.id)) }
                }
                .foregroundStyle(d.wrappedValue.projectID == nil && d.wrappedValue.checked ? Palette.warn : .primary)
                HStack {
                    TextField("Minutes", value: Binding(
                        get: { d.wrappedValue.estimateMin },
                        set: { d.wrappedValue.estimateMin = $0.flatMap { $0 > 0 ? $0 : nil }; d.wrappedValue.estimateGuessed = false }
                    ), format: .number)
                    .frame(maxWidth: 80)
                    Text("min").foregroundStyle(.secondary)
                    if d.wrappedValue.estimateGuessed { Text("guessed").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .opacity(d.wrappedValue.checked ? 1 : 0.5)
        }
    }

    private func save(_ current: [DraftTask]) {
        do {
            let n = try VoiceSave.save(current, projects: projects, in: ctx)
            drafts = nil; message = nil; speech.transcript = ""
            onSaved(n)
        } catch { message = "Couldn't save: \(error.localizedDescription)" }
    }
}
```

Editing an estimate clears "guessed", because the user typed it. `Palette.warn` lives in `SharedUI/Theme.swift`; check its name there.

- [ ] **Step 4: iPhone wiring.**
  - In `iOS/PhoneSync.swift`, add:

```swift
    struct NotSignedIn: LocalizedError { var errorDescription: String? { "Sign in to sort tasks automatically." } }

    func parseTasks(_ transcript: String, projects: [Project]) async throws -> [ParsedTask] {
        guard let engine, userID != nil else { throw NotSignedIn() }
        return try await engine.parseTasks(transcript: transcript, projects: projects)
    }
```

  - In `iOS/UI/RootView.swift`, change the enum to `enum Tab: Hashable { case today, tasks, dictate, week, rewards }` and put the Dictate tab between Tasks and Week:

```swift
                NavigationStack {
                    DictateView(parse: { try await sync.parseTasks($0, projects: $1) }) { _ in
                        sync.syncSoon(); tab = .tasks
                    }
                    .navigationTitle("Dictate")
                }
                .tabItem { Label("Dictate", systemImage: "mic.fill") }.tag(Tab.dictate)
```

- [ ] **Step 5: Mac wiring.**
  - In `Mac/App/SyncCoordinator.swift`, add:

```swift
    struct NotSignedIn: LocalizedError { var errorDescription: String? { "Sign in to sort tasks automatically." } }

    func parseTasks(_ transcript: String, projects: [Project]) async throws -> [ParsedTask] {
        guard let engine, userID != nil else { throw NotSignedIn() }
        return try await engine.parseTasks(transcript: transcript, projects: projects)
    }
```

  - In `Mac/UI/TodayView.swift`:
    - add `@Environment(SyncCoordinator.self) private var sync` and `@State private var dictating = false`;
    - put a `Button("Dictate tasks", systemImage: "mic") { dictating = true }` in the "This week" header `HStack`, right-aligned; wrap the existing `Text("This week")` in `HStack { Text(...); Spacer(); Button(...) }`;
    - attach to the `ScrollView`:

```swift
        .sheet(isPresented: $dictating) {
            DictateView(parse: { try await sync.parseTasks($0, projects: $1) }) { _ in
                dictating = false; sync.syncSoon()
            }
            .frame(minWidth: 560, minHeight: 520)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dictating = false } } }
        }
```

  - If `import Core` is missing in either file, add it so `ParsedTask` resolves.

- [ ] **Step 6: Build and test both apps.**

```bash
xcodegen generate
xcodebuild -scheme StintMac -derivedDataPath /private/tmp/claude-501/dd2 PRODUCT_BUNDLE_IDENTIFIER=dev.stint.mac.alt test 2>&1 | grep -E 'error:|Test run with|\*\* '
xcodebuild -project Stint.xcodeproj -scheme StintPhone -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath /private/tmp/claude-501/dd-ios test 2>&1 | grep -E 'error:|Test run with|\*\* '
cd Shared && swift test --disable-sandbox 2>&1 | tail -3
```

Expected: all three succeed and the earlier test counts still pass. `Test run with …` is the Swift Testing line; XCTest's "Executed 0 tests" is normal.

- [ ] **Step 7: Commit.**

```bash
git add SharedUI/SpeechCapture.swift SharedUI/DictateView.swift iOS/UI/RootView.swift iOS/PhoneSync.swift \
  Mac/App/SyncCoordinator.swift Mac/UI/TodayView.swift project.yml Mac/Stint.entitlements iOS/Info.plist Mac/Info.plist
git commit -m "feat(voice): dictate tasks on iPhone and Mac"
```

- [ ] **Step 8: Manual check (controller).** On the simulator, signed in, with at least one project synced:
  1. **Dictate tab without a key:** type "email Sam about the logo, then draft the Northwind invoice". Tap Make tasks. Expected: one editable task and "Couldn't sort this automatically…" (503 path).
  2. **Choose project:** pick a project, then Add 1 task. Expected: the task shows in Tasks and syncs to the Mac.
  3. **Too long:** paste over 4,000 characters. Expected: "That's over 4000 characters…", and nothing is sent.
  4. **Speech:** Record shows the permission prompts. If the simulator can't do on-device recognition, the typed path stays usable with the "isn't available" line.
  5. **With a key** (once the user has added `ANTHROPIC_API_KEY` to `supabase/functions/.env` and restarted the stack): the same sentence gives 2 tasks. "Northwind" is matched to the project, and the other task shows "Choose project".

---

## Done when

- `cd supabase/functions/parse-tasks && deno test` passes (5 tests). `deno check index.ts` is clean.
- `cd Shared && swift test --disable-sandbox` passes, including `VoiceTasksTests` and `VoiceSaveTests`.
- The Mac and iPhone `xcodebuild … test` runs pass.
- Manual checks 1–4 pass on the simulator. Check 5 runs once the user adds a key.
