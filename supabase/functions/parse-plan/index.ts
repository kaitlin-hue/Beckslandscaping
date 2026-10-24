import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const TOOL = {
  name: "build_plan",
  description: "Return Greg's day by day plan for one landscaping job.",
  input_schema: {
    type: "object",
    properties: {
      est_days: { type: "number", description: "Working days on site" },
      crew_size: { type: "integer", description: "Only if Greg said it" },
      tools: { type: "array", items: { type: "string" }, description: "Tools, plant and hire for the whole job, e.g. 1.7t excavator, plate compactor, laser level" },
      days: {
        type: "array",
        items: {
          type: "object",
          properties: {
            day_no: { type: "integer" },
            title: { type: "string", description: "Short headline for the day, e.g. Dig out and levelling" },
            steps: { type: "array", items: { type: "string" }, description: "Steps in order, short and plain, e.g. Solenoid check" },
            crew: { type: "integer" },
            tools: { type: "array", items: { type: "string" }, description: "Tools needed that day only" },
          },
          required: ["day_no", "title", "steps"],
        },
      },
      questions: { type: "array", items: { type: "string" }, description: "Max 2 short things Greg should confirm" },
    },
    required: ["days"],
  },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ error: "The Claude API key is not set yet." }, 503);
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: staff } = await sb.rpc("is_staff");
    if (!staff) return json({ error: "Not allowed" }, 403);
    const { transcript = "", job_id } = await req.json();
    if (!transcript) return json({ error: "Nothing to read" }, 400);
    const [{ data: job }, { data: tasks }, { data: settings }] = await Promise.all([
      sb.from("jobs").select("title,suburb,crew_size,notes,tools").eq("id", job_id).maybeSingle(),
      sb.from("job_tasks").select("task_type,description,qty,unit,est_hours").eq("job_id", job_id).order("seq"),
      sb.from("settings").select("hours_per_day,default_crew").single(),
    ]);
    const system = `You plan landscaping jobs for Beck's Landscaping in Perth, WA. Greg Beck talks his plan into his phone on site, fast and in his own words. Turn it into a day by day plan the crew can follow.
Rules
- One entry per working day, in order. Keep Greg's order and wording, tidy it up. Short steps, plain trade language, no dashes.
- Pull out every tool, machine and hire item he mentions (excavator, bobcat, plate compactor, laser level, concrete mixer, skip bin, wacker). Put job wide tools in tools, and day specific ones on that day.
- If he gives a total like "four days" but only details some, add the remaining days with a sensible headline from the job tasks and flag it in questions.
- Day is ${settings?.hours_per_day ?? 8} hours. Default crew ${job?.crew_size ?? settings?.default_crew ?? 2}.
Job: ${JSON.stringify(job ?? {})}
Tasks already on the job: ${JSON.stringify(tasks ?? [])}`;
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-5-5",
        max_tokens: 3000,
        system,
        tools: [TOOL],
        tool_choice: { type: "tool", name: "build_plan" },
        messages: [{ role: "user", content: `Greg's plan:\n${transcript}` }],
      }),
    });
    const out = await r.json();
    if (!r.ok) return json({ error: out?.error?.message ?? "Claude error" }, 502);
    const use = out.content?.find((c: { type: string }) => c.type === "tool_use");
    return json({ plan: use?.input ?? null });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
