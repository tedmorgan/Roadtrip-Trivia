// Shared rate limiting helper for Edge Functions
// PRD COST-05: Rate limit abusive patterns per account; prefer soft limits first.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Soft daily limits per PRD COST-05
const DAILY_LIMITS: Record<string, number> = {
  generate: 50,   // 50 rounds/day
  grade: 300,     // ~50 rounds x 5 questions + retries
  challenge: 50,  // 50 challenges/day
};

/**
 * Check and increment rate limit for a user action.
 * Returns { allowed: true } if under limit, or { allowed: false, message } if over.
 * Uses the service role key to bypass RLS.
 */
export async function checkRateLimit(
  userId: string,
  actionType: string
): Promise<{ allowed: boolean; message?: string; count?: number }> {
  if (!userId) {
    // No user ID means anonymous — allow but don't track
    return { allowed: true, count: 0 };
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data, error } = await supabase.rpc("increment_rate_limit", {
    p_user_id: userId,
    p_action_type: actionType,
  });

  if (error) {
    console.error(`[RateLimit] Error checking limit: ${error.message}`);
    // On error, allow the request (fail open per soft limit policy)
    return { allowed: true, count: 0 };
  }

  const count = data as number;
  const limit = DAILY_LIMITS[actionType] || 100;

  if (count > limit) {
    console.warn(
      `[RateLimit] User ${userId} exceeded ${actionType} limit: ${count}/${limit}`
    );
    return {
      allowed: false,
      count,
      message: `Daily limit reached for ${actionType}. Try again tomorrow.`,
    };
  }

  return { allowed: true, count };
}

/**
 * Extract user ID from the Authorization header (Supabase JWT).
 * Returns null if no valid auth header present.
 */
export function extractUserId(req: Request): string | null {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) return null;

  const token = authHeader.slice(7);
  try {
    // Decode the JWT payload (base64url) to get the user ID
    // This is a quick decode — Supabase verifies the token server-side
    const payloadB64 = token.split(".")[1];
    const payload = JSON.parse(atob(payloadB64));
    return payload.sub || null;
  } catch {
    return null;
  }
}
