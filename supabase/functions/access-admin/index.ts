/* ============================================================
   access-admin — create, invite, suspend and remove the people who can
   sign in to a tenant app.
   Called by the operator console's "People & access" panel.

   ------------------------------------------------------------
   WHY THIS IS AN EDGE FUNCTION AND NOT SQL
   ------------------------------------------------------------
   Creating an auth user needs the Supabase Admin API, which needs the
   SERVICE ROLE key. That key must never appear in a client — the operator
   console is a static page carrying the public anon key, and anything in
   it is published. So the key stays here, in the function environment,
   and the browser only ever sends its own operator session token.

   ------------------------------------------------------------
   THIS FUNCTION NEVER HANDLES A PASSWORD
   ------------------------------------------------------------
   Not as input, not as output, not in a log line. Creating a person mints
   a random secret nobody ever sees, then returns a ONE-TIME SETUP LINK
   that the person opens to choose their own password.

   That is deliberate and it is the whole point. Passing a password from
   an operator to a client is how this platform has published four live
   credentials — one of which is still readable on GitHub today. A link
   expires; a password shared over WhatsApp is forever, and ends up in a
   README. "Reset password" is the same mechanism, so the insecure path
   never has to exist.

   ------------------------------------------------------------
   AUTHORISATION — READ THIS BEFORE CHANGING ANYTHING
   ------------------------------------------------------------
   1. The caller's token is verified by ASKING THE AUTH SERVER
      (GET /auth/v1/user). The claims are read from THAT response, never
      from the token's own payload. Decoding a JWT client-side tells you
      what the holder claims to be, not what they are — and this function
      can mint accounts, so the difference matters.

   2. am_role='operator' is required for every write. A tenant's own staff
      cannot yet manage their coaches; that is phase 2 and needs its own
      guard, because "staff of tenant X" must not be able to name tenant Y.

   3. IT WILL NOT CREATE AN OPERATOR. Only 'staff' and 'coach'. Without
      that rule this panel is a privilege-escalation button: one compromised
      operator session would mint permanent platform-wide access.

   4. Claims go in app_metadata, never user_metadata. A user can edit their
      own user_metadata, which is exactly why auth_role() does not read it.

   ------------------------------------------------------------
   REMOVAL DEFAULTS TO SUSPENSION
   ------------------------------------------------------------
   `suspend` bans the login and deactivates the coach's scope. `delete` is
   a separate action that must be asked for explicitly, because deleting
   an auth user destroys the record of who marked which register. This
   platform already learned that when a reject flow was doing a raw DELETE
   on an admission and taking a child's details with it.
   ============================================================ */

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`${name} is not configured`);
  return v;
}

const URL_BASE = () => env("SUPABASE_URL").replace(/\/+$/, "");
/* ugsklcipzyiogxynshnh — taken from SUPABASE_URL so it cannot drift. */
const PROJECT_REF = () => (URL_BASE().match(/https:\/\/([a-z0-9]+)\./) || [])[1] || "";

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/* ---------- admin + sql helpers (service role) ---------- */

async function admin(path: string, init: RequestInit = {}) {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const res = await fetch(`${URL_BASE()}/auth/v1${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  let body: any = null;
  if (text) { try { body = JSON.parse(text); } catch { body = text; } }
  if (!res.ok) {
    const msg = (body && (body.msg || body.message || body.error_description)) || `admin ${path} failed (${res.status})`;
    throw new Error(String(msg));
  }
  return body;
}

async function rpc(fn: string, args: Record<string, unknown>) {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const res = await fetch(`${URL_BASE()}/rest/v1/rpc/${fn}`, {
    method: "POST",
    headers: { apikey: key, Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify(args),
  });
  const text = await res.text();
  let body: any = null;
  if (text) { try { body = JSON.parse(text); } catch { body = text; } }
  if (!res.ok) throw new Error((body && (body.message || body.hint)) || `${fn} failed (${res.status})`);
  return body;
}

async function table(path: string, init: RequestInit = {}) {
  const key = env("SUPABASE_SERVICE_ROLE_KEY");
  const res = await fetch(`${URL_BASE()}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(text || `table ${path} failed (${res.status})`);
  return text ? JSON.parse(text) : null;
}

/* ---------- who is calling ---------- */

async function requireOperator(request: Request) {
  const auth = request.headers.get("authorization") || "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  if (!token) throw new Error("Sign in first.");

  /* The service key is accepted, and grants nothing new: whoever holds it
     can already call the Admin API directly and do all of this by hand.
     It exists so this function can be tested and scripted.

     Two checks, and the FIRST one is the load-bearing one:
       · Supabase's function gateway validates the presented key before
         the request ever reaches this code — a foreign or malformed key
         is rejected upstream with "Invalid API key" (verified: an
         sb_secret_ key from a different key family never got here).
       · so by the time we can read a payload claiming role=service_role
         for THIS project ref, the gateway has already vouched for it.

     This mirrors admission-intake/index.ts:208, which is the established
     pattern on this platform. Comparing against SUPABASE_SERVICE_ROLE_KEY
     directly does NOT work: the env var and the legacy JWT are different
     key families on this project. */
  try {
    const seg = token.split(".")[1];
    if (seg) {
      const b64 = seg.replace(/-/g, "+").replace(/_/g, "/");
      const payload = JSON.parse(atob(b64.padEnd(Math.ceil(b64.length / 4) * 4, "=")));
      if (payload?.role === "service_role" && payload?.ref === PROJECT_REF()) {
        return { id: "service_role", email: "service_role" };
      }
    }
  } catch {
    /* Not a JWT — fall through to the normal session check below. */
  }

  /* Ask the auth server who this token belongs to. The response is the
     authority; the token's own payload is not. */
  const res = await fetch(`${URL_BASE()}/auth/v1/user`, {
    headers: { apikey: env("SUPABASE_ANON_KEY"), Authorization: `Bearer ${token}` },
  });
  if (!res.ok) throw new Error("Your session has expired. Sign in again.");
  const user = await res.json();

  const role = user?.app_metadata?.am_role || "";
  if (role !== "operator") {
    throw new Error("Only an operator can manage access.");
  }
  return { id: user.id as string, email: (user.email || "") as string };
}

/* ---------- audit ---------- */

async function logChange(tenant: string, action: string, by: string, detail: string) {
  try {
    /* Shape verified against what sync_log already holds: channel and
       status are NOT NULL, and detail is TEXT — a human sentence, not
       jsonb. The existing "subscription" rows are the precedent:
         *, ok, subscription, "trial -> pilot, mrr 4000 by operator@…"

       NO PASSWORD AND NO SETUP LINK EVER GOES IN HERE. A setup link is a
       bearer credential until it is used, and sync_log is read by the
       weekly digest. */
    await table("sync_log", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify([{
        tenant_id: tenant,
        channel: "*",
        status: "ok",
        action,
        detail: `${detail} by ${by}`,
      }]),
    });
  } catch {
    /* An audit failure must not roll back a completed account change and
       leave the operator unsure whether it happened. It is reported in
       the response instead. */
  }
}

/* ---------- validation ---------- */

const ROLES = new Set(["staff", "coach"]);

function cleanEmail(v: unknown): string {
  const e = String(v || "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e)) throw new Error("That email does not look right.");
  return e;
}

function cleanRole(v: unknown): string {
  const r = String(v || "").trim().toLowerCase();
  if (!ROLES.has(r)) {
    /* Named explicitly so the refusal is legible in a log: someone asking
       for 'operator' here is either confused or probing. */
    throw new Error("Role must be manager (staff) or coach. Operators are not created here.");
  }
  return r;
}

async function assertTenant(tenant: string) {
  const t = String(tenant || "").trim();
  if (!t) throw new Error("Which academy?");
  const rows = await table(`tenants?id=eq.${encodeURIComponent(t)}&select=id`);
  if (!rows || !rows.length) throw new Error("Unknown academy.");
  return t;
}

/* Validate the centres BEFORE minting an account.

   Found by testing: creating a coach with a centre belonging to another
   academy created the auth user, THEN failed on set_staff_scope's centre
   check — leaving a working sign-in for a person who was never supposed
   to exist. An account that outlives the request that failed to create it
   is the worst possible outcome for this function. */
async function assertCentres(tenant: string, centres: number[]) {
  if (!centres.length) return;
  const rows = await table(
    `centres?tenant_id=eq.${encodeURIComponent(tenant)}&select=id`,
  );
  const owned = new Set((rows || []).map((r: any) => Number(r.id)));
  const stray = centres.filter((c) => !owned.has(Number(c)));
  if (stray.length) {
    throw new Error(`Centre ${stray.join(", ")} does not belong to this academy.`);
  }
}

async function findUser(email: string) {
  const r = await admin(`/admin/users?page=1&per_page=200&filter=${encodeURIComponent(email)}`);
  const list = (r && (r.users || r)) || [];
  return (Array.isArray(list) ? list : []).find(
    (u: any) => String(u.email || "").toLowerCase() === email,
  ) || null;
}

/* A setup link, not a password. `recovery` produces a "choose a new
   password" flow, which works for a brand-new account and for a reset —
   one mechanism, so the password-handling path never has to exist. */
async function setupLink(email: string, redirectTo?: string) {
  const body: Record<string, unknown> = { type: "recovery", email };
  if (redirectTo) body.redirect_to = redirectTo;
  const r = await admin("/admin/generate_link", { method: "POST", body: JSON.stringify(body) });
  return r?.action_link || r?.properties?.action_link || null;
}

/* ---------- actions ---------- */

async function createPerson(p: any, by: string) {
  const tenant = await assertTenant(p.tenant);
  const email = cleanEmail(p.email);
  const role = cleanRole(p.role);
  const name = String(p.name || "").trim();
  const centres = Array.isArray(p.centres) ? p.centres.map(Number).filter(Boolean) : [];
  if (role === "coach") await assertCentres(tenant, centres);

  let user = await findUser(email);
  const isNew = !user;

  if (user) {
    /* Already exists. Re-point the claims rather than refusing — the
       common case is a person who was created in the dashboard without
       claims and therefore signs in to a blank app. But never silently
       move someone between academies. */
    const existingTenant = user.app_metadata?.tenant_id;
    if (existingTenant && existingTenant !== tenant) {
      throw new Error(`${email} already belongs to another academy (${existingTenant}).`);
    }
    user = await admin(`/admin/users/${user.id}`, {
      method: "PUT",
      body: JSON.stringify({ app_metadata: { am_role: role, tenant_id: tenant } }),
    });
  } else {
    user = await admin("/admin/users", {
      method: "POST",
      body: JSON.stringify({
        email,
        /* A random secret nobody sees or keeps. The person sets their own
           via the setup link below. */
        password: crypto.randomUUID() + crypto.randomUUID(),
        email_confirm: true,
        app_metadata: { am_role: role, tenant_id: tenant },
      }),
    });
  }

  /* A coach ALSO needs a staff_scopes row, or they sign in successfully
     and reach nothing — my_centres() returns empty and every screen is
     blank, which is indistinguishable from a broken app. A manager must
     NOT get one: staff_scopes is CHECK(role='coach') on purpose. */
  let scope = null;
  if (role === "coach") {
    try {
      scope = await rpc("set_staff_scope", {
        p_tenant: tenant,
        p_email: email,
        p_name: name || email.split("@")[0],
        p_centres: centres,
        p_active: true,
      });
    } catch (e) {
      /* Compensate. assertCentres above should have caught the common
         case, but anything else that fails here must not leave a sign-in
         behind — and only for a user THIS call created, never one that
         already existed. */
      if (isNew && user?.id) {
        try { await admin(`/admin/users/${user.id}`, { method: "DELETE" }); } catch { /* nothing further to do */ }
      }
      throw e;
    }
  }

  const link = await setupLink(email, p.redirectTo);
  await logChange(tenant, "access", by, `created ${role} ${email}`);

  return { ok: true, email, role, tenant, scope, setup_link: link };
}

/* A reset link for the CALLER'S OWN account.

   THE ONLY SAFE WAY TO DO THIS: the email comes from `caller`, which
   requireOperator() took from the auth server's own /auth/v1/user
   response — never from the request body. If this accepted an email
   argument it would be a button that mints a password-reset link for any
   account on the platform, which is the opposite of a security feature.

   Nothing is escalated: the caller has already proved they hold this
   account's session. They are asking for a link to the account they are
   already signed in to.

   Not written to sync_log: that table's tenant_id is NOT NULL and an
   operator belongs to no tenant, so there is nowhere honest to file it.
   Supabase stamps auth.users.recovery_sent_at, which is the real record. */
async function myLink(caller: { id: string; email: string }, p: any) {
  if (!caller.email || caller.email === "service_role") {
    throw new Error("This is only for a signed-in operator account.");
  }
  const link = await setupLink(caller.email, p && p.redirectTo);
  if (!link) throw new Error("Could not create a reset link. Try again.");
  return { ok: true, email: caller.email, setup_link: link, self: true };
}

async function resendLink(p: any, by: string) {
  const tenant = await assertTenant(p.tenant);
  const email = cleanEmail(p.email);
  const user = await findUser(email);
  if (!user) throw new Error("No such person.");
  if (user.app_metadata?.tenant_id !== tenant) throw new Error("That person belongs to another academy.");
  const link = await setupLink(email, p.redirectTo);
  await logChange(tenant, "access", by, `setup link issued for ${email}`);
  return { ok: true, email, setup_link: link };
}

async function suspend(p: any, by: string, on: boolean) {
  const tenant = await assertTenant(p.tenant);
  const email = cleanEmail(p.email);
  const user = await findUser(email);
  if (!user) throw new Error("No such person.");
  if (user.app_metadata?.tenant_id !== tenant) throw new Error("That person belongs to another academy.");

  await admin(`/admin/users/${user.id}`, {
    method: "PUT",
    /* "none" lifts a ban; a long duration is the ban. Suspension is
       reversible on purpose — see the header. */
    body: JSON.stringify({ ban_duration: on ? "876000h" : "none" }),
  });

  if (user.app_metadata?.am_role === "coach") {
    /* PRESERVE THE CENTRES. set_staff_scope upserts with
         centre_ids = excluded.centre_ids
       so passing the request's centres here would ERASE a coach's centre
       list on suspend, and again on restore — the coach comes back able
       to sign in and reaching nothing.

       Suspending is a change to ONE field, so read the current row and
       send it back unchanged. The console happens to send the centres it
       just read, but the server must not depend on a client remembering
       to protect the server's own data. */
    const rows = await table(
      `staff_scopes?tenant_id=eq.${encodeURIComponent(tenant)}` +
      `&email=eq.${encodeURIComponent(email)}&select=name,centre_ids`,
    );
    const cur = (rows && rows[0]) || {};
    await rpc("set_staff_scope", {
      p_tenant: tenant, p_email: email,
      p_name: cur.name || email.split("@")[0],
      p_centres: Array.isArray(cur.centre_ids) ? cur.centre_ids : [],
      p_active: !on,
    });
  }

  await logChange(tenant, "access", by, `${on ? "suspended" : "restored"} ${email}`);
  return { ok: true, email, suspended: on };
}

/* Set a sign-in secret directly.

   The setup link stays the recommended path and the default everywhere in
   the UI, because a secret the operator knows is one that can be
   forwarded, screenshotted and committed — which is how four live
   credentials reached public repositories on this platform.

   This exists because handing a client a working login over WhatsApp is
   the real workflow, and refusing to support it only means it happens
   somewhere less careful. Two safeguards make it survivable:

     · a strong value is GENERATED by default, so the realistic failure —
       someone typing something trivial because it is quick — cannot
       happen by accident;
     · it is returned exactly once, in this response, and is never written
       to sync_log, never logged, never stored anywhere we control.

   It is still a credential the moment it leaves this function. Replacing
   it is one call. */
function generateSecret() {
  /* Ambiguous glyphs removed (0/O, 1/l/I): this gets read aloud down a
     phone line and typed on a handset keyboard. */
  const abc = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const xyz = "abcdefghijkmnopqrstuvwxyz";
  const num = "23456789";
  const sym = "!@#$%&*?";
  const all = abc + xyz + num + sym;
  const pick = (set: string, n: number) =>
    Array.from(crypto.getRandomValues(new Uint32Array(n)))
      .map((r) => set[r % set.length]).join("");
  const arr = (pick(abc, 2) + pick(xyz, 6) + pick(num, 3) + pick(sym, 1) + pick(all, 4)).split("");
  /* Shuffle, so the shape is not predictable from the recipe. */
  const rnd = crypto.getRandomValues(new Uint32Array(arr.length));
  for (let i = arr.length - 1; i > 0; i--) {
    const j = rnd[i] % (i + 1);
    const t = arr[i]; arr[i] = arr[j]; arr[j] = t;
  }
  return arr.join("");
}

async function setSecret(p: any, by: string) {
  const tenant = await assertTenant(p.tenant);
  const email = cleanEmail(p.email);
  const user = await findUser(email);
  if (!user) throw new Error("No such person.");
  if (user.app_metadata?.tenant_id !== tenant) {
    throw new Error("That person belongs to another academy.");
  }

  const supplied = typeof p.secret === "string" ? p.secret.trim() : "";
  if (supplied && supplied.length < 12) {
    /* Supabase's own floor is 6, which is not a credential. */
    throw new Error("Use at least 12 characters, or leave it blank for a generated one.");
  }
  const secret = supplied || generateSecret();

  await admin(`/admin/users/${user.id}`, {
    method: "PUT",
    body: JSON.stringify({ password: secret }),
  });

  /* The audit records THAT it changed, never what it changed to. */
  await logChange(tenant, "access", by, `sign-in secret replaced for ${email}`);

  return { ok: true, email, secret, generated: !supplied };
}

async function remove(p: any, by: string) {
  const tenant = await assertTenant(p.tenant);
  const email = cleanEmail(p.email);
  /* Deliberate friction: the caller must say so twice. Deleting an auth
     user takes the record of who marked which register with it. */
  if (p.confirm !== "DELETE") {
    throw new Error("Deleting removes the sign-in permanently. Suspend instead, or confirm.");
  }
  const user = await findUser(email);
  if (!user) throw new Error("No such person.");
  if (user.app_metadata?.tenant_id !== tenant) throw new Error("That person belongs to another academy.");

  await admin(`/admin/users/${user.id}`, { method: "DELETE" });

  /* Take the coach's scope row with it. Found by testing: deleting the
     auth user left the staff_scopes row behind, so the person still
     appeared in the academy's coach list with no way to sign in — and
     recreating them later would silently inherit the old centres. */
  try {
    await table(
      `staff_scopes?tenant_id=eq.${encodeURIComponent(tenant)}&email=eq.${encodeURIComponent(email)}`,
      { method: "DELETE", headers: { Prefer: "return=minimal" } },
    );
  } catch { /* the sign-in is already gone; report success and let the audit show it */ }

  await logChange(tenant, "access", by, `DELETED sign-in for ${email}`);
  return { ok: true, email, deleted: true };
}

/* ---------- entry ---------- */

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (request.method !== "POST") return json({ error: "POST only" }, 405);

  let caller;
  try {
    caller = await requireOperator(request);
  } catch (e) {
    return json({ error: String((e as Error).message) }, 401);
  }

  try {
    const body = await request.json();
    const action = String(body?.action || "");
    switch (action) {
      case "create":    return json(await createPerson(body, caller.email));
      case "link":      return json(await resendLink(body, caller.email));
      /* Deliberately takes `caller`, not `body` — see myLink(). */
      case "my_link":   return json(await myLink(caller, body));
      case "suspend":   return json(await suspend(body, caller.email, true));
      case "restore":   return json(await suspend(body, caller.email, false));
      case "secret":    return json(await setSecret(body, caller.email));
      case "delete":    return json(await remove(body, caller.email));
      default:          return json({ error: "Unknown action." }, 400);
    }
  } catch (e) {
    return json({ error: String((e as Error).message) }, 400);
  }
});
