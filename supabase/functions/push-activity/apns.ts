import { importPKCS8, SignJWT } from "@panva/jose";

export type ApnsConfig = { keyId: string; teamId: string; privateKey: string; topic: string; host: string };

/** Token-based APNs auth (ES256). Apple wants the JWT reused for 20–60 min, so it's cached for 50. */
export function apnsSender(cfg: ApnsConfig): (token: string, payload: unknown) => Promise<number> {
  // Lazy: a malformed key must fail a send (counted as failed), not crash the worker at boot.
  let key: ReturnType<typeof importPKCS8> | null = null;
  let cached: { jwt: string; at: number } | null = null;
  async function bearer(): Promise<string> {
    const now = Math.floor(Date.now() / 1000);
    if (cached && now - cached.at < 50 * 60) return cached.jwt;
    const jwt = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: cfg.keyId })
      .setIssuer(cfg.teamId).setIssuedAt(now).sign(await (key ??= importPKCS8(cfg.privateKey.replaceAll("\\n", "\n"), "ES256")));
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
