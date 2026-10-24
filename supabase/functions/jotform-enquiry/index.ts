// Jotform webhook -> Beck's Hub enquiry.
// Jotform posts multipart/form-data with a rawRequest JSON of the answers. We map the
// answers by field name and hand them to public.submit_enquiry, the same door the hub uses.
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

function pick(raw: Record<string, unknown>, re: RegExp): unknown {
  for (const k of Object.keys(raw)) if (re.test(k.replace(/^q\d+_/, ""))) return raw[k];
  return undefined;
}
const str = (v: unknown): string => {
  if (v == null) return "";
  if (typeof v === "string") return v.trim();
  if (Array.isArray(v)) return v.map(str).filter(Boolean).join(", ");
  if (typeof v === "object") return Object.values(v as Record<string, unknown>).map(str).filter(Boolean).join(" ");
  return String(v);
};

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("ok", { status: 200 });
  let raw: Record<string, unknown> = {};
  let pretty = "";
  const ct = req.headers.get("content-type") || "";
  try {
    if (ct.includes("multipart/form-data") || ct.includes("application/x-www-form-urlencoded")) {
      const form = await req.formData();
      const rr = form.get("rawRequest");
      if (typeof rr === "string") raw = JSON.parse(rr);
      pretty = String(form.get("pretty") || "");
    } else {
      const body = await req.json();
      raw = typeof body.rawRequest === "string" ? JSON.parse(body.rawRequest) : (body.rawRequest || body);
      pretty = String(body.pretty || "");
    }
  } catch (e) {
    return new Response(`bad payload: ${e}`, { status: 400 });
  }

  const name = str(pick(raw, /name/i));
  const phone = str(pick(raw, /mobile|phone/i));
  const email = str(pick(raw, /email/i));
  const addrRaw = pick(raw, /address/i);
  const address = typeof addrRaw === "object" && addrRaw ? [ (addrRaw as any).addr_line1, (addrRaw as any).addr_line2 ].filter(Boolean).join(" ") : str(addrRaw);
  const suburb = str(pick(raw, /suburb/i)) || (typeof addrRaw === "object" && addrRaw ? str((addrRaw as any).city) : "");
  const typesRaw = pick(raw, /projecttype|project_type|type/i);
  const project_types = Array.isArray(typesRaw) ? typesRaw.map(str) : str(typesRaw) ? str(typesRaw).split(/,\s*/) : [];
  const description = str(pick(raw, /description/i));
  const budget = str(pick(raw, /budget/i));
  const start_pref = str(pick(raw, /start|when/i));
  const contact_pref = str(pick(raw, /contact/i));
  const enquiring_as = str(pick(raw, /enquiring/i));
  const heard = str(pick(raw, /hear/i));
  const source = str(pick(raw, /^source$|source/i)) || heard;
  const honeypot = str(pick(raw, /empty/i));

  const payload = {
    name, phone, email, address, suburb, description: description || "Jotform enquiry",
    project_types, budget, start_pref, contact_pref, enquiring_as,
    source: source ? `Jotform: ${source}` : "Jotform",
    website: honeypot, elapsed_ms: 60000,
  };
  const { data, error } = await sb.rpc("submit_enquiry", { p: payload });
  // keep the raw submission so a bad mapping can be fixed without losing the lead
  await sb.from("automation_log").insert({
    action: "note",
    detail: error ? `Jotform enquiry failed for ${name || email}: ${error.message}. Pretty: ${pretty.slice(0, 600)}` : `Jotform enquiry in: ${name} (${suburb})`,
    needs_check: !!error,
  });
  if (error) return new Response(JSON.stringify({ ok: false, error: error.message }), { status: 200, headers: { "Content-Type": "application/json" } });
  return new Response(JSON.stringify(data ?? { ok: true }), { status: 200, headers: { "Content-Type": "application/json" } });
});
