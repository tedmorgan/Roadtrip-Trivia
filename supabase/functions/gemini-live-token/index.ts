import { corsHeaders } from "../_shared/cors.ts";
import { extractUserId } from "../_shared/ratelimit.ts";

const GEMINI_AUTH_TOKENS_URL =
  "https://generativelanguage.googleapis.com/v1beta/auth_tokens";
const MODEL = "gemini-3.1-flash-live-preview";

function log(message: string, detail?: unknown) {
  const timestamp = new Date().toISOString();
  if (detail === undefined) {
    console.log(`[${timestamp}] gemini-live-token: ${message}`);
  } else {
    console.log(`[${timestamp}] gemini-live-token: ${message}`, detail);
  }
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // Supabase's function gateway validates the JWT because verify_jwt is enabled.
  // Keep this explicit guard so a deployment configuration regression fails closed.
  const userId = extractUserId(req);
  if (!userId) {
    log("rejected unauthenticated request");
    return jsonResponse({ error: "Authentication required" }, 401);
  }

  try {
    const apiKey = (Deno.env.get("GEMINI_API_KEY") ?? "")
      .trim()
      .replace(/^['"]|['"]$/g, "");
    if (!apiKey) {
      throw new Error("GEMINI_API_KEY not configured");
    }

    const now = Date.now();
    const expireTime = new Date(now + 30 * 60 * 1000).toISOString();
    const newSessionExpireTime = new Date(now + 60 * 1000).toISOString();

    log("minting constrained ephemeral token", {
      model: MODEL,
      userId,
      expireTime,
      newSessionExpireTime,
    });

    const response = await fetch(GEMINI_AUTH_TOKENS_URL, {
      method: "POST",
      headers: {
        "x-goog-api-key": apiKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        uses: 1,
        expireTime,
        newSessionExpireTime,
        fieldMask:
          "model,generationConfig.responseModalities,sessionResumption",
        bidiGenerateContentSetup: {
          model: `models/${MODEL}`,
          generationConfig: {
            responseModalities: ["AUDIO"],
          },
          sessionResumption: {},
        },
      }),
    });

    const responseText = await response.text();
    if (!response.ok) {
      log("Gemini rejected token request", {
        status: response.status,
        body: responseText.slice(0, 500),
      });
      return jsonResponse({
        error: "Unable to create Gemini Live session",
        upstreamStatus: response.status,
        upstreamError: responseText.slice(0, 500),
      }, 502);
    }

    const token = JSON.parse(responseText) as { name?: string };
    if (!token.name) {
      throw new Error("Gemini token response did not include a token name");
    }

    log("issued constrained ephemeral token", {
      model: MODEL,
      userId,
      expiresAt: expireTime,
    });
    return jsonResponse({
      value: token.name,
      expires_at: Math.floor(new Date(expireTime).getTime() / 1000),
      new_session_expires_at:
        Math.floor(new Date(newSessionExpireTime).getTime() / 1000),
      model: MODEL,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log("request failed", { message });
    return jsonResponse({ error: message }, 500);
  }
});
