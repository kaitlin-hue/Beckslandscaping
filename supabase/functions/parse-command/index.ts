import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// "Tell the hub": Greg talks, this turns it into hub actions. Nothing is saved here.
// The hub shows the actions back and Greg taps Apply.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const STAGES = ["Lead","Design","Quoted","Accepted","Deposit in","Materials ordered","On site","Complete","Invoiced","Paid","Lost"];

const TOOL = {
  name: "hub_actions",
  description: "Turn what Greg said into actions the hub can apply.",
  input_schema: {
    type: "object",
    properties: {
      actions: {
        type: "array",
        items: {
          type: "object",
          properties: {
            type: { type: "string", enum: ["add_client","add_note","follow_up","move_stage","set_start","mark_lost","update_client","watch"] },
            summary: { type: "string", description: "One plain line Greg will read before applying, e.g. 'Add client Jenny Smith, Floreat, 0412 000 000'" },
            client_id: { type: "string", description: "id from the clients list when the person is already a client" },
            job_id: { type: "string", description: "id from the jobs list when a job is meant" },
            name: { type: "string" }, phone: { type: "string" }, email: { type: "string" },
            address: { type: "string" }, suburb: { type: "string" }, source: { type: "string", description: "How they found Beck's, if said" },
            kind: { type: "string", description: "For notes: Note, Call, Text, Email, Site visit. For watch: Supplier, Materials, Tools, Client, Pricing, Crew, Site, Lesson, Other" },
            note: { type: "string" },
            follow_up_on: { type: "string", description: "YYYY-MM-DD when Greg must do something next" },
            stage: { type: "string", enum: STAGES },
            start_date: { type: "string", description: "YYYY-MM-DD" },
            crew_size: { type: "number" },
            reason: { type: "string" },
          },
          required: ["type", "summary"],
        },
      },
      questions: { type: "array", items: { type: "string" }, description: "Max 3 short things Greg must clear up before this can be applied" },
    },
    required: ["actions"],
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

    const { transcript = "" } = await req.json();
    if (!transcript.trim()) return json({ error: "Nothing to read" }, 400);

    const [{ data: clients }, { data: jobs }] = await Promise.all([
      sb.from("clients").select("id,name,suburb,phone").order("created_at", { ascending: false }).limit(300),
      sb.from("jobs").select("id,title,suburb,stage,start_date,clients(name)").not("stage", "in", "(Paid,Lost)").order("created_at", { ascending: false }).limit(120),
    ]);
    const today = new Date(Date.now() + 8 * 3600e3).toISOString().slice(0, 10);
    const jobList = (jobs ?? []).map((j: Record<string, unknown>) => ({ id: j.id, client: (j.clients as { name?: string } | null)?.name ?? "", suburb: j.suburb, title: j.title, stage: j.stage, start: j.start_date }));
    const clientList = (clients ?? []).map((c: Record<string, unknown>) => ({ id: c.id, name: c.name, suburb: c.suburb }));

    const system = `You turn what Greg Beck (Beck's Landscaping, Perth WA) says into hub actions. Today is ${today}.

What you can do
- add_client: a new person Greg mentions with at least a name. Phone, email, address, suburb, source if said. If the name already matches a client, use update_client with their client_id instead.
- add_note: something to remember against a client (what they want, what was agreed). kind is Note, Call, Text, Email or Site visit.
- follow_up: Greg must do something on a date ("call her Thursday", "chase in two weeks"). Give follow_up_on and a short note. Resolve weekdays and relative dates from today.
- move_stage: a job moves to a named stage. Stages: ${STAGES.join(", ")}. "Booked" means Accepted. "Started" means On site. "Finished" means Complete.
- set_start: a start date for a job, and crew size if said.
- mark_lost: a job is lost, with the reason if given.
- watch: something Greg must keep an eye on or remember for next time (a supplier running late, a tool to replace, how a client is, what to price differently). kind is Supplier, Materials, Tools, Client, Pricing, Crew, Site, Lesson or Other.
- A new job or a quote is not an action here: put "Use New quote for <name>" in questions.

Rules
- Match people by name or suburb against the clients and jobs lists. Use ids from the lists. If more than one could fit, ask in questions rather than guess.
- Never invent phone numbers, dates, prices or reasons. If a date is vague ("sometime next month"), ask.
- One action per thing Greg said. Keep summary lines short and plain. No dashes.

Clients: ${JSON.stringify(clientList)}
Jobs: ${JSON.stringify(jobList)}`;

    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-5-5",
        max_tokens: 2000, system, tools: [TOOL], tool_choice: { type: "tool", name: "hub_actions" },
        messages: [{ role: "user", content: `Greg said:\n${transcript}` }],
      }),
    });
    const out = await r.json();
    if (!r.ok) return json({ error: out?.error?.message ?? "Claude error" }, 502);
    const use = out.content?.find((c: { type: string }) => c.type === "tool_use");
    return json({ result: use?.input ?? { actions: [], questions: ["Nothing I could turn into an action"] } });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
