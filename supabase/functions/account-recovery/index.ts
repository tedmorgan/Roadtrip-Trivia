import { jsonResponse, lookupProfile, passwordGrant, sendMagicLink, sendPasswordRecovery, patchUserMetadata, logSupport } from "../_shared/support.ts";
import { mailerFailureMessage, planRecoveryEmails } from "../_shared/supportPolicy.ts";

const GENERIC_PASSWORD =
  "If an account exists for that email or username, we sent a password reset link.";
const GENERIC_USERNAME =
  "If an account exists for that email, we sent a username reminder and a sign-in link.";
const GENERIC_MAGIC =
  "If an account exists for that email, we sent a sign-in link.";

interface Body {
  action?: string;
  identifier?: string;
  email?: string;
  password?: string;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return jsonResponse({ ok: true });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON" }, 400);
  }

  const action = (body.action ?? "").trim();
  logSupport("account-recovery", { action });

  try {
    switch (action) {
      case "sign_in":
        return await handleSignIn(body);
      case "forgot_password":
        return await handleForgotPassword(body);
      case "forgot_username":
        return await handleForgotUsername(body);
      case "magic_link":
        return await handleMagicLink(body);
      default:
        return jsonResponse({ error: "Unknown action" }, 400);
    }
  } catch (error) {
    logSupport("account-recovery failed", {
      error: error instanceof Error ? error.message : String(error),
    });
    return jsonResponse({ error: "Request failed" }, 500);
  }
});

async function handleSignIn(body: Body): Promise<Response> {
  const identifier = (body.identifier ?? "").trim();
  const password = body.password ?? "";
  if (!identifier || !password) {
    return jsonResponse({ error: "Enter your email or username" }, 400);
  }

  let email = identifier;
  if (!identifier.includes("@")) {
    const profile = await lookupProfile(identifier);
    if (!profile?.email) {
      return jsonResponse({ error: "Invalid email or password" }, 401);
    }
    email = profile.email;
  }

  const grant = await passwordGrant(email, password);
  const text = await grant.text();
  if (!grant.ok) {
    return jsonResponse({ error: "Invalid email or password" }, 401);
  }
  return new Response(text, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
    },
  });
}

async function handleForgotPassword(body: Body): Promise<Response> {
  const identifier = (body.identifier ?? body.email ?? "").trim();
  if (!identifier) {
    return jsonResponse({ error: "Enter the email or username on the account" }, 400);
  }
  const profile = await lookupProfile(identifier);
  const planned = planRecoveryEmails("forgot_password", identifier, profile ? {
    id: profile.id,
    username: profile.username,
    usernameNormalized: profile.username_normalized,
    profileEmail: profile.email,
    authEmail: null,
    displayName: profile.display_name,
    metadataName: null,
    createdAt: profile.created_at,
  } : null);
  if (planned.length === 0) {
    return jsonResponse({ ok: true, message: GENERIC_PASSWORD });
  }
  if (profile) await patchUserMetadata(profile.id, profile.username);
  const sent = await sendPasswordRecovery(planned[0].to);
  if (!sent.ok) return mailerFailure(sent.error);
  return jsonResponse({ ok: true, message: GENERIC_PASSWORD });
}

async function handleForgotUsername(body: Body): Promise<Response> {
  const email = (body.email ?? body.identifier ?? "").trim();
  if (!email.includes("@")) {
    return jsonResponse({ error: "Enter a valid email address" }, 400);
  }
  const profile = await lookupProfile(email);
  const planned = planRecoveryEmails("forgot_username", email, profile ? {
    id: profile.id,
    username: profile.username,
    usernameNormalized: profile.username_normalized,
    profileEmail: profile.email,
    authEmail: null,
    displayName: profile.display_name,
    metadataName: null,
    createdAt: profile.created_at,
  } : null);
  if (planned.length > 0 && profile) {
    await patchUserMetadata(profile.id, profile.username);
    const sent = await sendMagicLink(planned[0].to);
    if (!sent.ok) return mailerFailure(sent.error);
  }
  return jsonResponse({ ok: true, message: GENERIC_USERNAME });
}

async function handleMagicLink(body: Body): Promise<Response> {
  const email = (body.email ?? body.identifier ?? "").trim();
  if (!email.includes("@")) {
    return jsonResponse({ error: "Enter a valid email address" }, 400);
  }
  const profile = await lookupProfile(email);
  const sent = await sendMagicLink(profile?.email ?? email);
  if (!sent.ok) return mailerFailure(sent.error);
  return jsonResponse({ ok: true, message: GENERIC_MAGIC });
}

function mailerFailure(error: string | undefined): Response {
  return jsonResponse({ ok: false, error: mailerFailureMessage(error) }, 429);
}
