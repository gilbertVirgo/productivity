/** The gateway has already verified the JWT (verify_jwt = true in config.jsonc); this only reads its claims. */
export function role(req: Request): string | null {
  const token = req.headers.get("Authorization")?.replace(/^Bearer /, "") ?? "";
  try {
    const b64 = token.split(".")[1].replaceAll("-", "+").replaceAll("_", "/");
    return JSON.parse(atob(b64 + "=".repeat((4 - b64.length % 4) % 4))).role ?? null;
  } catch { return null; }
}
