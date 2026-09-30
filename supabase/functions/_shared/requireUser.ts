/**
 * Confirm the caller is a signed-in user.
 *
 * The platform `verify_jwt` gate only accepts legacy HS256 tokens. After the
 * project moved to ES256 signing keys, that gate answers 401
 * UNAUTHORIZED_ASYMMETRIC_JWT and the function never runs. These functions
 * set verify_jwt = false and ask Auth's /user endpoint, which accepts the
 * current signing key. supabase-js getUser() is not used here: on the edge
 * runtime it can drop the passed-in token and report a missing session.
 */
export async function requireUserId(req: Request): Promise<string | null> {
  const result = await requireUser(req);
  return "id" in result ? result.id : null;
}

export async function requireUser(
  req: Request,
): Promise<{ id: string } | { error: string }> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    return { error: "Missing bearer token" };
  }
  const jwt = authHeader.slice("Bearer ".length).trim();
  if (!jwt) return { error: "Missing bearer token" };

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) return { error: "Auth is not configured" };

  const response = await fetch(`${url}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${jwt}`,
      apikey: anonKey,
    },
  });
  const body = await response.text();
  if (!response.ok) {
    const timestamp = new Date().toISOString();
    console.log(
      `[${timestamp}] requireUser: auth rejected status=${response.status} body=${body.slice(0, 300)}`,
    );
    let message = "Authentication required";
    try {
      const parsed = JSON.parse(body) as { msg?: string; message?: string; error?: string };
      message = parsed.msg || parsed.message || parsed.error || message;
    } catch {
      if (body.trim()) message = body.slice(0, 180);
    }
    return { error: message };
  }
  try {
    const user = JSON.parse(body) as { id?: string };
    if (!user.id) return { error: "Authentication required" };
    return { id: user.id };
  } catch {
    return { error: "Authentication required" };
  }
}
