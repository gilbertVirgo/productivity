import { handle } from "./parse.ts";
import { claudeCaller } from "./claude.ts";

const key = Deno.env.get("ANTHROPIC_API_KEY");
const call = key ? claudeCaller(key) : null; // no key: 503, and the apps fall back to one editable task

Deno.serve((req) => handle(req, call));
