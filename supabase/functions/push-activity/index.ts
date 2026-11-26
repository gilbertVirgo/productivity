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
