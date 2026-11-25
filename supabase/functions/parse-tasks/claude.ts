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
