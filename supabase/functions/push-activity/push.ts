import { role } from "../_shared/auth.ts";

export type Device = { push_to_start_token: string | null; activity_token: string | null; activity_session_id: string | null };
export type Deps = {
  /** The caller's own rows (RLS), read with the caller's Authorization and apikey headers. */
  devices: (auth: string, apikey: string) => Promise<Device[]>;
  /** Sends one APNs request; returns the HTTP status. */
  send: (token: string, payload: unknown) => Promise<number>;
};

const EVENTS = ["start", "update", "end"];
// Live Activity tokens are variable-length (a simulator push-to-start token is 256 hex chars); cap only to bound the URL.
const HEX = /^[0-9a-fA-F]{4,1024}$/;
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

  const statuses = await Promise.all(tokens.map((t) => deps.send(t, { aps }).catch((e) => {
    console.error("apns send:", e instanceof Error ? e.message : e);
    return 0;
  })));
  const sent = statuses.filter((s) => s === 200).length;
  return json(200, { sent, failed: statuses.length - sent });
}
