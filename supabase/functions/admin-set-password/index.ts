import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

// Owner or admin sets a new password for someone on the team. The admin types the password;
// nothing is generated or stored here beyond the auth update itself.

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user } } = await asUser.auth.getUser();
    if (!user) return json({ error: "Log in first" }, 401);
    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const { data: me } = await admin.from("profiles").select("role,name").eq("id", user.id).maybeSingle();
    if (!me || !["owner", "admin"].includes(me.role)) return json({ error: "Only Greg or Kaitlin can reset passwords" }, 403);

    const { user_id, password } = await req.json();
    if (!user_id || typeof password !== "string") return json({ error: "Pick a person and type a password" }, 400);
    if (password.length < 8) return json({ error: "Use at least 8 characters" }, 400);
    if (user_id === user.id) return json({ error: "Change your own under Change my password" }, 400);

    const { data: target } = await admin.from("profiles").select("name").eq("id", user_id).maybeSingle();
    if (!target) return json({ error: "That person isn't on the team" }, 404);
    const { error } = await admin.auth.admin.updateUserById(user_id, { password });
    if (error) return json({ error: error.message }, 400);

    await admin.from("automation_log").update({ checked_at: new Date().toISOString(), checked_by: user.id })
      .eq("action", "reset_request").is("checked_at", null).ilike("ref", (target.name || "").toLowerCase());
    await admin.from("automation_log").insert({ action: "note", detail: `Password reset for ${target.name} by ${me.name}`, needs_check: false });
    return json({ ok: true, name: target.name });
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
