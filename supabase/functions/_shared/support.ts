import {
  authEmailPayload,
  exactSupportAccount,
  parseMailerError,
  type SupportAccount,
} from "./supportPolicy.ts";

const supabaseUrl = () => Deno.env.get("SUPABASE_URL") ?? "";
const serviceKey = () => Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const anonKey = () => Deno.env.get("SUPABASE_ANON_KEY") ?? "";

export function jsonResponse(body: unknown, status = 200, extra: HeadersInit = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      ...extra,
    },
  });
}

function restHeaders(key: string, extra: Record<string, string> = {}) {
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
    ...extra,
  };
}

export async function rest<T = unknown>(
  path: string,
  init: RequestInit = {},
): Promise<{ status: number; body: T }> {
  const response = await fetch(`${supabaseUrl()}/rest/v1/${path}`, {
    ...init,
    headers: {
      ...restHeaders(serviceKey()),
      ...(init.headers as Record<string, string> | undefined),
    },
  });
  const text = await response.text();
  let body: T;
  try {
    body = text ? JSON.parse(text) as T : [] as T;
  } catch {
    body = text as T;
  }
  return { status: response.status, body };
}

export interface ProfileRow {
  id: string;
  username: string | null;
  username_normalized: string | null;
  email: string | null;
  display_name: string | null;
  is_admin: boolean | null;
  created_at: string | null;
}

export interface SubscriptionRow {
  user_id: string;
  product_id: string | null;
  status: string | null;
  purchased_rounds: number | null;
  subscription_rounds_used: number | null;
  support_rounds_granted: number | null;
  support_rounds_clawed_back: number | null;
  free_round_used: boolean | null;
  rounds_played_total: number | null;
}

export function classifyIdentifier(raw: string): "email" | "username" {
  return raw.trim().includes("@") ? "email" : "username";
}

function asSupportAccount(row: ProfileRow): SupportAccount {
  return {
    id: row.id,
    username: row.username,
    usernameNormalized: row.username_normalized,
    profileEmail: row.email,
    authEmail: null,
    displayName: row.display_name,
    metadataName: null,
    createdAt: row.created_at,
  };
}

export async function lookupProfiles(query: string): Promise<ProfileRow[]> {
  const value = query.trim();
  if (!value) return [];

  const { status, body } = await rest<ProfileRow[]>("rpc/search_support_profiles", {
    method: "POST",
    body: JSON.stringify({ p_query: value }),
  });
  if (status >= 400 || !Array.isArray(body)) {
    logSupport("search_support_profiles failed", { status, body });
    return [];
  }
  return body;
}

export async function lookupProfile(query: string): Promise<ProfileRow | null> {
  const rows = await lookupProfiles(query);
  const exact = exactSupportAccount(query, rows.map(asSupportAccount));
  if (!exact) return null;
  return rows.find((row) => row.id === exact.id) ?? null;
}

export async function loadSubscription(userId: string): Promise<SubscriptionRow | null> {
  const { body } = await rest<SubscriptionRow[]>(
    `subscriptions?user_id=eq.${userId}&select=*`,
  );
  if (!Array.isArray(body) || body.length === 0) return null;
  return body[0];
}

export async function ensureSubscription(userId: string): Promise<void> {
  await rest("rpc/ensure_subscription_row", {
    method: "POST",
    body: JSON.stringify({ p_user_id: userId }),
  });
}

export interface MailerResult {
  ok: boolean;
  error?: string;
}

async function sendAuthEmail(path: string, email: string): Promise<MailerResult> {
  const response = await fetch(`${supabaseUrl()}${path}`, {
    method: "POST",
    headers: restHeaders(anonKey()),
    body: JSON.stringify(authEmailPayload(email)),
  });
  if (response.ok) return { ok: true };
  const text = await response.text();
  const message = parseMailerError(text);
  logSupport("auth email failed", { path, status: response.status, message });
  return { ok: false, error: message };
}

export async function sendPasswordRecovery(email: string): Promise<MailerResult> {
  return await sendAuthEmail("/auth/v1/recover", email);
}

export async function sendMagicLink(email: string): Promise<MailerResult> {
  return await sendAuthEmail("/auth/v1/magiclink", email);
}

export async function passwordGrant(email: string, password: string): Promise<Response> {
  return await fetch(`${supabaseUrl()}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: restHeaders(anonKey()),
    body: JSON.stringify({ email, password }),
  });
}

export async function getUserFromJwt(token: string): Promise<{ id: string; email: string | null } | null> {
  const response = await fetch(`${supabaseUrl()}/auth/v1/user`, {
    headers: {
      apikey: anonKey(),
      Authorization: `Bearer ${token}`,
    },
  });
  if (!response.ok) return null;
  const json = await response.json() as { id?: string; email?: string };
  if (!json.id) return null;
  return { id: json.id, email: json.email ?? null };
}

export async function isAdmin(userId: string): Promise<boolean> {
  const { body } = await rest<ProfileRow[]>(
    `profiles?id=eq.${userId}&select=is_admin`,
  );
  return Array.isArray(body) && body[0]?.is_admin === true;
}

export async function patchUserMetadata(userId: string, username: string | null): Promise<void> {
  if (!username) return;
  await fetch(`${supabaseUrl()}/auth/v1/admin/users/${userId}`, {
    method: "PUT",
    headers: restHeaders(serviceKey()),
    body: JSON.stringify({ user_metadata: { username } }),
  });
}

export async function fetchAuthUser(userId: string): Promise<Record<string, unknown> | null> {
  const response = await fetch(`${supabaseUrl()}/auth/v1/admin/users/${userId}`, {
    headers: restHeaders(serviceKey()),
  });
  if (!response.ok) return null;
  const json = await response.json() as { user?: Record<string, unknown> } & Record<string, unknown>;
  return json.user ?? json;
}

export function compensationNet(granted: number, clawedBack: number): number {
  return Math.max(0, granted - Math.max(0, clawedBack));
}

export function logSupport(message: string, detail?: unknown) {
  const timestamp = new Date().toISOString();
  if (detail === undefined) {
    console.log(`[${timestamp}] support: ${message}`);
  } else {
    console.log(`[${timestamp}] support: ${message}`, detail);
  }
}
