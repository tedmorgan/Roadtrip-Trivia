import {
  compensationNet,
  ensureSubscription,
  fetchAuthUser,
  getUserFromJwt,
  isAdmin,
  jsonResponse,
  loadSubscription,
  logSupport,
  lookupProfile,
  lookupProfiles,
  patchUserMetadata,
  rest,
  sendMagicLink,
  sendPasswordRecovery,
} from "../_shared/support.ts";
import { classifyLookup, playableRounds, subscriptionRoundsLeft } from "../_shared/supportPolicy.ts";

interface AdminBody {
  action?: string;
  query?: string;
  rounds?: number;
  note?: string;
  appleTransactionID?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return jsonResponse({ ok: true });
  }
  if (req.method === "GET") {
    return new Response(adminHtml(), {
      headers: {
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
      },
    });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  const auth = req.headers.get("Authorization") ?? "";
  const token = auth.replace(/^Bearer\s+/i, "").trim();
  const actor = token ? await getUserFromJwt(token) : null;
  if (!actor || !(await isAdmin(actor.id))) {
    return jsonResponse({ error: "Support tools require an admin account" }, 403);
  }

  let body: AdminBody;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const action = (body.action ?? "").trim();
  const query = (body.query ?? "").trim();
  logSupport("admin-console", { action, actor: actor.id });

  try {
    switch (action) {
      case "lookup":
        return jsonResponse(await handleLookup(query));
      case "sendPasswordReset":
        return jsonResponse(await handlePasswordReset(actor.id, query, body.note ?? ""));
      case "sendUsernameReminder":
        return jsonResponse(await handleUsernameReminder(actor.id, query, body.note ?? ""));
      case "creditRounds":
        return jsonResponse(await handleCredit(actor.id, query, body));
      case "recordRefund":
        return jsonResponse(await handleRefund(actor.id, query, body));
      default:
        return jsonResponse({ error: "Unknown action" }, 400);
    }
  } catch (error) {
    logSupport("admin-console failed", {
      error: error instanceof Error ? error.message : String(error),
    });
    return jsonResponse({ error: "Request failed" }, 500);
  }
});

async function handleLookup(query: string) {
  if (!query) return { error: "Search by email, username, name, or account ID" };
  const profiles = await lookupProfiles(query);
  if (classifyLookup(profiles.length) === "empty") return { error: "No account matched that search" };
  if (classifyLookup(profiles.length) === "many") {
    return {
      matches: profiles.map((profile) => ({
        id: profile.id,
        email: profile.email,
        username: profile.username,
        displayName: profile.display_name,
      })),
    };
  }
  return await snapshot(profiles[0].id);
}

async function handlePasswordReset(actorId: string, query: string, note: string) {
  const snapshotBody = await requireProfile(query);
  if ("error" in snapshotBody) return snapshotBody;
  const email = snapshotBody.profile.email as string | null;
  if (!email) {
    return { error: "This account has no email — Apple Hide My Email or social-only. Ask them to use Sign in with Apple/Google." };
  }
  await patchUserMetadata(snapshotBody.profile.id as string, snapshotBody.profile.username as string | null);
  const sent = await sendPasswordRecovery(email);
  if (!sent.ok) return { error: sent.error || "Password reset email was not sent" };
  await logAction(actorId, snapshotBody.profile.id as string, "sendPasswordReset", 0, note || "Password reset emailed", "");
  return { ...await snapshot(snapshotBody.profile.id as string), message: `Password reset sent to ${email}. It opens the app so they can choose a new password.` };
}

async function handleUsernameReminder(actorId: string, query: string, note: string) {
  const snapshotBody = await requireProfile(query);
  if ("error" in snapshotBody) return snapshotBody;
  const email = snapshotBody.profile.email as string | null;
  const username = snapshotBody.profile.username as string | null;
  if (!email) {
    return { error: "This account has no email, so a username reminder cannot be sent." };
  }
  await patchUserMetadata(snapshotBody.profile.id as string, username);
  const sent = await sendMagicLink(email);
  if (!sent.ok) return { error: sent.error || "Username email was not sent" };
  await logAction(actorId, snapshotBody.profile.id as string, "sendUsernameReminder", 0, note || `Username reminder (${username ?? "none set"})`, "");
  return {
    ...await snapshot(snapshotBody.profile.id as string),
    message: username
      ? `Username reminder sent to ${email}. Username on file: ${username}`
      : `Sign-in link sent to ${email}. No username is set on this account.`,
  };
}

async function handleCredit(actorId: string, query: string, body: AdminBody) {
  const rounds = Number(body.rounds ?? 0);
  const note = (body.note ?? "").trim();
  if (rounds < 1 || rounds > 50) return { error: "Credit 1–50 rounds" };
  if (!note) return { error: "Add a reason for the credit" };
  const snapshotBody = await requireProfile(query);
  if ("error" in snapshotBody) return snapshotBody;
  const userId = snapshotBody.profile.id as string;
  await ensureSubscription(userId);
  const sub = await loadSubscription(userId);
  const granted = (sub?.support_rounds_granted ?? 0) + rounds;
  await rest(`subscriptions?user_id=eq.${userId}`, {
    method: "PATCH",
    body: JSON.stringify({ support_rounds_granted: granted }),
  });
  await logAction(actorId, userId, "creditRounds", rounds, note, body.appleTransactionID ?? "");
  return {
    ...await snapshot(userId),
    message: `Credited ${rounds} round${rounds === 1 ? "" : "s"}. Player sees them after opening the app.`,
  };
}

async function handleRefund(actorId: string, query: string, body: AdminBody) {
  const rounds = Number(body.rounds ?? 0);
  const note = (body.note ?? "").trim();
  if (!note) return { error: "Add a refund note for the audit log" };
  if (rounds < 0 || rounds > 50) return { error: "Claw back 0–50 rounds" };
  const snapshotBody = await requireProfile(query);
  if ("error" in snapshotBody) return snapshotBody;
  const userId = snapshotBody.profile.id as string;
  await ensureSubscription(userId);
  const sub = await loadSubscription(userId);
  const clawed = (sub?.support_rounds_clawed_back ?? 0) + rounds;
  const purchased = Math.max(0, (sub?.purchased_rounds ?? 0) - rounds);
  await rest(`subscriptions?user_id=eq.${userId}`, {
    method: "PATCH",
    body: JSON.stringify({
      support_rounds_clawed_back: clawed,
      purchased_rounds: purchased,
    }),
  });
  await logAction(
    actorId,
    userId,
    "recordRefund",
    rounds,
    note,
    body.appleTransactionID ?? "",
  );
  return {
    ...await snapshot(userId),
    message: rounds > 0
      ? `Recorded refund and clawed back ${rounds} round${rounds === 1 ? "" : "s"}.`
      : "Refund recorded. No rounds clawed back.",
  };
}

async function requireProfile(query: string) {
  if (!query.trim()) return { error: "Search by email, username, name, or account ID" };
  const profiles = await lookupProfiles(query);
  if (classifyLookup(profiles.length) === "empty") return { error: "No account matched that search" };
  if (classifyLookup(profiles.length) === "many") {
    return { error: "Several accounts matched. Open one account from the list, then try again." };
  }
  return { profile: profiles[0] };
}

async function snapshot(userId: string) {
  const profile = await lookupProfile(userId);
  if (!profile) return { error: "Account disappeared" };
  await ensureSubscription(userId);
  const subscription = await loadSubscription(userId);
  const authUser = await fetchAuthUser(userId);
  const { body: actions } = await rest<Array<Record<string, unknown>>>(
    `support_actions?user_id=eq.${userId}&select=id,action,rounds,note,apple_transaction_id,created_at,actor_id&order=created_at.desc&limit=20`,
  );
  const granted = subscription?.support_rounds_granted ?? 0;
  const clawed = subscription?.support_rounds_clawed_back ?? 0;
  const providers = Array.isArray((authUser as { identities?: Array<{ provider?: string }> } | null)?.identities)
    ? ((authUser as { identities: Array<{ provider?: string }> }).identities.map((i) => i.provider).filter(Boolean))
    : [];
  return {
    profile: {
      id: profile.id,
      username: profile.username,
      email: profile.email || (authUser as { email?: string } | null)?.email || null,
      displayName: profile.display_name,
      createdAt: profile.created_at,
      isAdmin: profile.is_admin === true,
    },
    billing: {
      productId: subscription?.product_id ?? null,
      status: subscription?.status ?? "none",
      purchasedRounds: subscription?.purchased_rounds ?? 0,
      subscriptionRoundsUsed: subscription?.subscription_rounds_used ?? 0,
      subscriptionRoundsLeft: subscriptionRoundsLeft({
        subscriptionProductId: subscription?.product_id ?? null,
        subscriptionStatus: subscription?.status ?? "none",
        subscriptionRoundsUsed: subscription?.subscription_rounds_used ?? 0,
      }),
      playableRounds: playableRounds({
        freeRoundUsed: subscription?.free_round_used ?? false,
        purchasedRounds: subscription?.purchased_rounds ?? 0,
        subscriptionProductId: subscription?.product_id ?? null,
        subscriptionStatus: subscription?.status ?? "none",
        subscriptionRoundsUsed: subscription?.subscription_rounds_used ?? 0,
      }),
      supportGranted: granted,
      supportClawedBack: clawed,
      compensationNet: compensationNet(granted, clawed),
      freeRoundUsed: subscription?.free_round_used ?? false,
      roundsPlayedTotal: subscription?.rounds_played_total ?? 0,
    },
    providers,
    lastSignInAt: (authUser as { last_sign_in_at?: string } | null)?.last_sign_in_at ?? null,
    actions: Array.isArray(actions) ? actions : [],
  };
}

async function logAction(
  actorId: string,
  userId: string,
  action: string,
  rounds: number,
  note: string,
  appleTransactionID: string,
) {
  await rest("support_actions", {
    method: "POST",
    body: JSON.stringify({
      actor_id: actorId,
      user_id: userId,
      action,
      rounds,
      note,
      apple_transaction_id: appleTransactionID || null,
    }),
  });
}

function adminHtml(): string {
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Roadtrip Trivia Support</title>
  <style>
    :root { --bg:#0d0221; --card:#1a0a2e; --pink:#ff2d95; --cyan:#00ffff; --green:#00ff65; --orange:#ff6b00; --muted:#9b7ed9; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: ui-sans-serif, system-ui, sans-serif; background:linear-gradient(#1a0a2e,#0d0221); color:#fff; min-height:100vh; }
    main { max-width: 920px; margin: 0 auto; padding: 24px 16px 64px; }
    h1 { color: var(--pink); margin: 0 0 8px; }
    p.lede, .setup { color: var(--muted); margin-top: 0; }
    .setup { padding-left: 1.2rem; }
    .setup li { margin: 6px 0; }
    code { color: var(--cyan); }
    .card { background: rgba(26,10,46,.85); border: 1px solid #6b00cc55; border-radius: 14px; padding: 16px; margin: 16px 0; }
    label { display:block; font-size: 12px; color: var(--cyan); margin: 10px 0 4px; letter-spacing:.04em; text-transform:uppercase; }
    input, textarea, button, select { width:100%; padding:10px 12px; border-radius:10px; border:1px solid #6b00cc; background:#0d0221; color:#fff; font-size:16px; }
    textarea { min-height: 72px; }
    button { cursor:pointer; font-weight:700; margin-top:10px; }
    button.primary { background:#ff2d9533; border-color: var(--pink); color:#fff; }
    button.ok { background:#00ff6533; border-color: var(--green); }
    button.warn { background:#ff6b0033; border-color: var(--orange); }
    .row { display:grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .msg { margin-top:12px; color: var(--green); }
    .err { color: var(--orange); }
    dl { display:grid; grid-template-columns: 160px 1fr; gap: 6px 12px; margin:0; }
    dt { color: var(--muted); } dd { margin:0; word-break: break-all; }
    table { width:100%; border-collapse: collapse; font-size: 13px; }
    th, td { text-align:left; padding:8px 6px; border-bottom:1px solid #6b00cc44; }
    .hidden { display:none; }
    @media (max-width: 640px) { .row { grid-template-columns: 1fr; } dl { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<main>
  <h1>Roadtrip Trivia Support</h1>
  <p class="lede">Look up a player, reset access, credit rounds, or record a refund. Staff sign-in uses an email account, not the Supabase dashboard login. There is no “update profiles” button under Authentication.</p>
  <ol class="setup">
    <li>Open the <a href="https://supabase.com/dashboard/project/kakhzbcuudkrrktkobjs/auth/users" style="color:#00ffff">Roadtrip Trivia users page</a>. Click <strong>Add user</strong>, then <strong>Create new user</strong>. Enter your email and a password, and turn on <strong>Auto Confirm User</strong>.</li>
    <li>Open <a href="https://supabase.com/dashboard/project/kakhzbcuudkrrktkobjs/editor" style="color:#00ffff">Table Editor</a> in the left sidebar (not Authentication). Select the <strong>profiles</strong> table. Find the row with your email and set <strong>is_admin</strong> to true. Save the row.</li>
    <li>Come back here and sign in with that same email and password.</li>
  </ol>

  <section id="login" class="card">
    <h2>Staff sign-in</h2>
    <label>Email</label>
    <input id="staffEmail" type="email" autocomplete="username" />
    <label>Password</label>
    <input id="staffPassword" type="password" autocomplete="current-password" />
    <button class="primary" id="staffSignIn">Sign in</button>
    <p id="loginMsg" class="msg"></p>
  </section>

  <section id="desk" class="hidden">
    <div class="card">
      <label>Find account (email, username, or UUID)</label>
      <input id="query" placeholder="ted@example.com or roadwarrior" />
      <button class="primary" id="lookup">Look up</button>
      <p id="deskMsg" class="msg"></p>
    </div>
    <div id="result" class="hidden">
      <div class="card">
        <h2>Account</h2>
        <dl id="accountDl"></dl>
      </div>
      <div class="row">
        <div class="card">
          <h2>Lost password / username</h2>
          <button class="ok" id="sendReset">Email password reset</button>
          <button class="ok" id="sendUsername">Email username reminder</button>
        </div>
        <div class="card">
          <h2>Credit rounds</h2>
          <label>Rounds (1–50)</label>
          <input id="creditRounds" type="number" min="1" max="50" value="3" />
          <label>Reason</label>
          <textarea id="creditNote" placeholder="Goodwill for interrupted game"></textarea>
          <button class="ok" id="credit">Credit rounds</button>
        </div>
      </div>
      <div class="card">
        <h2>Record refund</h2>
        <div class="row">
          <div>
            <label>Rounds to claw back (0–50)</label>
            <input id="refundRounds" type="number" min="0" max="50" value="0" />
          </div>
          <div>
            <label>Apple transaction ID (optional)</label>
            <input id="txn" placeholder="100000123456" />
          </div>
        </div>
        <label>Note</label>
        <textarea id="refundNote" placeholder="App Store refund 18 Sep 2026"></textarea>
        <button class="warn" id="refund">Record refund</button>
      </div>
      <div class="card">
        <h2>Support history</h2>
        <table>
          <thead><tr><th>When</th><th>Action</th><th>Rounds</th><th>Note</th></tr></thead>
          <tbody id="history"></tbody>
        </table>
      </div>
    </div>
  </section>
</main>
<script>
  const CONFIG = ${JSON.stringify({
    supabaseUrl,
    anonKey,
    apiUrl: `${supabaseUrl}/functions/v1/admin-console`,
  })};
  let token = sessionStorage.getItem("rt_support_token") || "";
  let currentQuery = "";

  const $ = (id) => document.getElementById(id);
  const setMsg = (id, text, isError) => {
    const el = $(id);
    el.textContent = text || "";
    el.className = "msg" + (isError ? " err" : "");
  };

  function showDesk(signedIn) {
    $("login").classList.toggle("hidden", signedIn);
    $("desk").classList.toggle("hidden", !signedIn);
  }

  async function authSignIn() {
    setMsg("loginMsg", "");
    const email = $("staffEmail").value.trim();
    const password = $("staffPassword").value;
    const res = await fetch(CONFIG.supabaseUrl + "/auth/v1/token?grant_type=password", {
      method: "POST",
      headers: { apikey: CONFIG.anonKey, "Content-Type": "application/json" },
      body: JSON.stringify({ email, password }),
    });
    const json = await res.json();
    if (!res.ok || !json.access_token) {
      setMsg("loginMsg", json.error_description || json.msg || json.message || "Sign-in failed", true);
      return;
    }
    token = json.access_token;
    sessionStorage.setItem("rt_support_token", token);
    const probe = await api({ action: "lookup", query: email });
    if (probe && probe.error === "Support tools require an admin account") {
      token = "";
      sessionStorage.removeItem("rt_support_token");
      setMsg("loginMsg", "This account is not authorized for support tools. Set profiles.is_admin = true.", true);
      return;
    }
    showDesk(true);
  }

  async function api(payload) {
    const res = await fetch(CONFIG.apiUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: "Bearer " + token,
        apikey: CONFIG.anonKey,
      },
      body: JSON.stringify(payload),
    });
    const json = await res.json();
    if (res.status === 403) {
      showDesk(false);
      setMsg("loginMsg", json.error || "Admin session expired", true);
    }
    return json;
  }

  function renderSnapshot(data) {
    if (data.error) {
      $("result").classList.add("hidden");
      setMsg("deskMsg", data.error, true);
      return;
    }
    currentQuery = data.profile.id;
    $("result").classList.remove("hidden");
    if (data.message) setMsg("deskMsg", data.message, false);
    else setMsg("deskMsg", "");
    const p = data.profile, b = data.billing;
    const rows = [
      ["Email", p.email || "(none)"],
      ["Username", p.username || "(not set)"],
      ["Account ID", p.id],
      ["Display name", p.displayName || ""],
      ["Providers", (data.providers || []).join(", ") || "email"],
      ["Last sign-in", data.lastSignInAt || ""],
      ["Subscription", (b.status || "none") + (b.productId ? " · " + b.productId : "")],
      ["Purchased rounds", String(b.purchasedRounds)],
      ["Support credits (net)", b.compensationNet + " (granted " + b.supportGranted + ", clawed " + b.supportClawedBack + ")"],
      ["Free round used", b.freeRoundUsed ? "yes" : "no"],
    ];
    $("accountDl").innerHTML = rows.map(([k,v]) => "<dt>"+k+"</dt><dd>"+escapeHtml(v)+"</dd>").join("");
    $("history").innerHTML = (data.actions || []).map((a) =>
      "<tr><td>"+escapeHtml(a.created_at||"")+"</td><td>"+escapeHtml(a.action||"")+"</td><td>"+escapeHtml(String(a.rounds||0))+"</td><td>"+escapeHtml(a.note||"")+"</td></tr>"
    ).join("") || "<tr><td colspan=4>No support actions yet</td></tr>";
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
  }

  $("staffSignIn").onclick = authSignIn;
  $("lookup").onclick = async () => {
    const q = $("query").value.trim();
    currentQuery = q;
    renderSnapshot(await api({ action: "lookup", query: q }));
  };
  $("sendReset").onclick = async () => renderSnapshot(await api({ action: "sendPasswordReset", query: currentQuery }));
  $("sendUsername").onclick = async () => renderSnapshot(await api({ action: "sendUsernameReminder", query: currentQuery }));
  $("credit").onclick = async () => renderSnapshot(await api({
    action: "creditRounds",
    query: currentQuery,
    rounds: Number($("creditRounds").value),
    note: $("creditNote").value,
  }));
  $("refund").onclick = async () => renderSnapshot(await api({
    action: "recordRefund",
    query: currentQuery,
    rounds: Number($("refundRounds").value),
    note: $("refundNote").value,
    appleTransactionID: $("txn").value,
  }));

  if (token) showDesk(true);
</script>
</body>
</html>`;
}
