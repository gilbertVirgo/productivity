import { role } from "../_shared/auth.ts";
export const MAX_TRANSCRIPT = 4000; // Unicode scalars; the apps count the same way
export type Project = { id: string; name: string };
export type ParsedTask = { title: string; project_id: string | null; estimate_min: number | null; estimate_guessed: boolean };
export type Caller = (transcript: string, projects: Project[]) => Promise<unknown>;

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

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
  ).slice(0, 200).map(({ id, name }) => ({ id, name: name.slice(0, 100) }));
  if (!call) return json(503, { error: "ai_unavailable" });
  try {
    return json(200, { tasks: clean(await call(transcript, projects), projects) });
  } catch (e) {
    console.error("parse-tasks:", e instanceof Error ? e.message : e);
    return json(502, { error: "ai_failed" });
  }
}
