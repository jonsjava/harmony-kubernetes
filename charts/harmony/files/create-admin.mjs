// Creates (or promotes) the instance admin: a port of upstream
// self-host/admin.sh `create`. GoTrue's admin API creates the account with the
// address confirmed, the account signs in and inserts its profile as the app
// does, the federation backend generates its keys, and the service role marks
// it admin. An existing account keeps its password and is only promoted.
// Then applies harmony.registration to instance_config.open_registration.
//
// Env: SUPABASE_URL SUPABASE_ANON_KEY SUPABASE_SERVICE_ROLE_KEY FEDERATION_URL
//      ADMIN_EMAIL ADMIN_USERNAME ADMIN_PASSWORD ADMIN_DISPLAY_NAME REGISTRATION
const BASE = process.env.SUPABASE_URL.replace(/\/$/, "");
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const ANON = process.env.SUPABASE_ANON_KEY;
const email = (process.env.ADMIN_EMAIL || "").toLowerCase();
const username = (process.env.ADMIN_USERNAME || "").toLowerCase();
const password = process.env.ADMIN_PASSWORD || "";
const displayName = process.env.ADMIN_DISPLAY_NAME || username;
const registration = process.env.REGISTRATION || "";

function fail(msg, r) {
  let detail = "";
  if (r) {
    const j = r.json || {};
    detail = ` (HTTP ${r.status}: ${String(j.msg || j.message || j.error_description || j.error || r.text || "").slice(0, 300)})`;
  }
  console.error(`Error: ${msg}${detail}`);
  process.exit(1);
}

async function call(method, path, { key = SERVICE, bearer, body, headers = {} } = {}) {
  const res = await fetch(BASE + path, {
    method,
    headers: { apikey: key, Authorization: `Bearer ${bearer ?? key}`, "Content-Type": "application/json", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch {}
  return { status: res.status, ok: res.ok, json, text };
}

async function findUserByEmail(addr) {
  for (let page = 1; page <= 100; page++) {
    const r = await call("GET", `/auth/v1/admin/users?page=${page}&per_page=200&filter=${encodeURIComponent(addr)}`);
    if (!r.ok) fail("listing accounts failed", r);
    const users = r.json?.users ?? [];
    const hit = users.find((u) => (u.email || "").toLowerCase() === addr);
    if (hit) return hit;
    if (users.length < 200) return null;
  }
  return null;
}

async function profileById(id) {
  const r = await call("GET", `/rest/v1/profiles?id=eq.${id}&select=id,username,is_admin,is_local`);
  if (!r.ok) fail("reading profiles failed", r);
  return r.json?.[0] ?? null;
}

const signIn = (addr, pw) => call("POST", "/auth/v1/token?grant_type=password", { key: ANON, body: { email: addr, password: pw } });
const signOut = (token) => call("POST", "/auth/v1/logout?scope=local", { key: ANON, bearer: token });

if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) fail("ADMIN_EMAIL is not an email address");
if (!/^[a-z0-9_]{3,24}$/.test(username)) fail("ADMIN_USERNAME must be 3-24 characters of a-z, 0-9 and _");
if (password.length < 8) fail("the admin password needs at least 8 characters");

// GoTrue and PostgREST may still be starting.
for (let i = 0; ; i++) {
  try {
    const r = await call("GET", "/rest/v1/instance_config?config_key=eq.domain&select=config_value");
    if (r.ok) break;
    if (i >= 60) fail("Supabase REST did not answer", r);
  } catch (e) {
    if (i >= 60) fail(`Supabase unreachable at ${BASE}: ${e.message}`);
  }
  await new Promise((res) => setTimeout(res, 5000));
}

const dr = await call("GET", "/rest/v1/instance_config?config_key=eq.domain&select=config_value");
if (!dr.ok) fail("reading instance_config failed", dr);
const domain = typeof dr.json?.[0]?.config_value === "string" ? dr.json[0].config_value : "";
if (!domain || domain === "localhost") fail("instance_config.domain is not set yet; the migrations job sets it");

let user = await findUserByEmail(email);
let created = false;
if (!user) {
  const r = await call("POST", "/auth/v1/admin/users", { body: { email, password, email_confirm: true } });
  if (!r.ok) fail("creating the account failed", r);
  user = r.json;
  created = true;
}

let profile = await profileById(user.id);
if (!profile) {
  const taken = await call("GET",
    `/rest/v1/profiles?username=eq.${encodeURIComponent(username)}&domain=eq.${encodeURIComponent(domain)}&is_local=eq.true&select=id`);
  if (!taken.ok) fail("checking the username failed", taken);
  if (taken.json?.length) fail(`the username ${username} belongs to another account`);
  if (!created) {
    const r = await call("PUT", `/auth/v1/admin/users/${user.id}`, { body: { password, email_confirm: true } });
    if (!r.ok) fail("setting the password failed", r);
  }
  const s = await signIn(email, password);
  if (!s.ok) fail("signing in as the new account failed", s);
  const token = s.json.access_token;
  const actor = `https://${domain}/users/${username}`;
  const pr = await call("POST", "/rest/v1/profiles", {
    key: ANON,
    bearer: token,
    headers: { Prefer: "return=representation" },
    body: {
      id: user.id,
      auth_user_id: user.id,
      username,
      display_name: displayName,
      color: "#0EA5E9",
      is_local: true,
      domain,
      federated_id: actor,
      inbox_url: `${actor}/inbox`,
      outbox_url: `${actor}/outbox`,
      followers_url: `${actor}/followers`,
      following_url: `${actor}/following`,
    },
  });
  await signOut(token);
  if (!pr.ok) fail("creating the profile failed", pr);
  profile = pr.json?.[0];
  try {
    await fetch(`${process.env.FEDERATION_URL}/generate-keys`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ user_id: user.id }),
    });
  } catch {
    // The actor endpoint generates keys on first request.
  }
}

if (!profile.is_admin) {
  const r = await call("PATCH", `/rest/v1/profiles?id=eq.${user.id}`, {
    headers: { Prefer: "return=representation" },
    body: { is_admin: true },
  });
  if (!r.ok || !r.json?.[0]?.is_admin) fail("promoting the account to admin failed", r);
  console.log(` ✓ ${username} <${email}> is an instance admin${created ? " (new account)" : ""}`);
} else {
  console.log(` ✓ ${profile.username} <${email}> is already an instance admin`);
}

if (registration) {
  const open = registration === "open";
  const r = await call("PATCH", "/rest/v1/instance_config?config_key=eq.open_registration", {
    body: { config_value: open },
  });
  if (!r.ok) fail("updating instance_config.open_registration failed", r);
  console.log(` ✓ Registration: ${registration} (open_registration=${open})`);
}
