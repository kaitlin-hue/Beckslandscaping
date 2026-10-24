import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Turns Greg's end-of-day voice note into crew days per job and problems on site.
// Owner and admin only. Nothing is saved here: the hub shows it back for Greg to check first.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const CATEGORIES = ["Tools and gear", "Safety", "Materials and suppliers", "Time and lateness", "Client", "Quality", "Other"];

const TOOL = {
  name: "log_day",
  description: "Return who worked on which job, when, and any problems Greg mentioned.",
  input_schema: {
    type: "object",
    properties: {
      date: { type: "string", description: "YYYY-MM-DD of the work day. Today unless Greg names another day (yesterday, Friday)." },
      entries: {
        type: "array",
        description: "One row per person per job. If someone moved between jobs, give one row for each job with its own times.",
        items: {
          type: "object",
          properties: {
            name: { type: "string", description: "First name, matched to the crew list where it fits" },
            job_id: { type: "string", description: "id from the jobs list, or empty if no job fits" },
            job_heard: { type: "string", description: "How Greg referred to the job, e.g. 'Pearse in Claremont'" },
            start: { type: "string", description: "24h HH:MM if said" },
            end: { type: "string", description: "24h HH:MM if said" },
            hours: { type: "number", description: "Hours worked on this job. From start and end less the break if times were given, else what Greg said, else the standard day." },
            is_variation: { type: "boolean", description: "True only if Greg says the work was extra or a variation" },
            note: { type: "string" },
          },
          required: ["name", "hours"],
        },
      },
      issues: {
        type: "array",
        description: "Problems, delays, near misses or things to raise at the Monday toolbox meeting",
        items: {
          type: "object",
          properties: {
            job_id: { type: "string" },
            category: { type: "string", enum: CATEGORIES },
            note: { type: "string", description: "Plain, factual, one sentence" },
            people: { type: "array", items: { type: "string" } },
            lost_hours: { type: "number", description: "Person hours lost, only if Greg said or it is clear" },
          },
          required: ["category", "note"],
        },
      },
      new_people: { type: "array", items: { type: "string" }, description: "Names not on the crew list" },
      questions: { type: "array", items: { type: "string" }, description: "Max 3 short things Greg must confirm" },
    },
    required: ["entries", "issues"],
  },
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const key = Deno.env.get("ANTHROPIC_API_KEY");
    if (!key) return json({ error: "The Claude API key is not set yet. Add ANTHROPIC_API_KEY in Supabase secrets." }, 503);

    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: staff } = await sb.rpc("is_staff");
    if (!staff) return json({ error: "Not allowed" }, 403);

    const { transcript = "", date = "" } = await req.json();
    if (!transcript.trim()) return json({ error: "Nothing to read" }, 400);

    const [{ data: settings }, { data: crew }, { data: jobs }] = await Promise.all([
      sb.from("settings").select("*").single(),
      sb.from("crew").select("name").eq("active", true),
      sb.from("jobs").select("id,title,suburb,stage,start_date,end_date,clients(name)")
        .not("stage", "in", "(Paid,Lost)").order("start_date", { ascending: true, nullsFirst: false }).limit(80),
    ]);

    const today = date || new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10); // Perth
    const hpd = settings?.hours_per_day ?? 8;
    const brk = settings?.break_minutes ?? 30;
    const jobList = (jobs ?? []).map((j: Record<string, unknown>) => ({
      id: j.id, client: (j.clients as { name?: string } | null)?.name ?? "", suburb: j.suburb, title: j.title,
      stage: j.stage, on: j.start_date ? `${j.start_date} to ${j.end_date}` : "",
    }));

    const system = `You log the work day for Beck's Landscaping in Perth, WA. Greg Beck talks fast at the end of the day. Today is ${today}.

Rules
- One entry per person per job. If someone split the day ("Troy went between two jobs"), make an entry for each job with its own times.
- Times are 24 hour. "7 till 4" is 07:00 to 16:00. Hours = end minus start, less a ${brk} minute break if they were on site over 5 hours that day. A plain "full day" is ${hpd} hours, "half day" is ${hpd / 2}.
- Match jobs by client surname, suburb or what the job is. Use the job id from the list. Jobs on the board this week are the most likely. If nothing fits, leave job_id empty and say what you heard.
- Crew list: ${(crew ?? []).map((c: { name: string }) => c.name).join(", ")}. Greg is the owner; only log Greg if he says he worked on the tools. Names not on the list go in new_people.
- Problems become issues for the Monday toolbox meeting: tools left behind, late starts, supplier delays, safety, client requests, rework. Keep each note factual and short. Name the people only if Greg did.
- Never invent hours, names or problems. If something is unclear, ask in questions.
- Plain words. No dashes.

Jobs: ${JSON.stringify(jobList)}`;

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-5-5",
        max_tokens: 3000,
        system,
        tools: [TOOL],
        tool_choice: { type: "tool", name: "log_day" },
        messages: [{ role: "user", content: `Greg's day:\n${transcript}` }],
      }),
    });
    const out = await r.json();
    if (!r.ok) return json({ error: out?.error?.message ?? "Claude error" }, 502);
    const use = out.content?.find((c: { type: string }) => c.type === "tool_use");
    return json({ day: use?.input ?? null });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
