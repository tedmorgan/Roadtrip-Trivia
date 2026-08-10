import { corsHeaders } from "../_shared/cors.ts";

/// Mint a short-lived xAI Realtime client secret for the iOS app.
///
/// Deploy:
///   supabase secrets set XAI_API_KEY=xai-...
///   supabase functions deploy grok-token
///
/// POST /grok-token
/// Returns: { "value": "xai-realtime-...", "expires_at": 1750000000,
///            "model": "grok-voice-think-fast-2.0" }

const XAI_CLIENT_SECRETS_URL =
  "https://api.x.ai/v1/realtime/client_secrets";
const MODEL = "grok-voice-think-fast-2.0";

function log(message: string, detail?: unknown) {
  const timestamp = new Date().toISOString();
  if (detail === undefined) {
    console.log(`[${timestamp}] grok-token: ${message}`);
  } else {
    console.log(`[${timestamp}] grok-token: ${message}`, detail);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  try {
    // Trim / strip accidental quotes from dashboard paste.
    const rawKey = Deno.env.get("XAI_API_KEY") ?? "";
    const apiKey = rawKey.trim().replace(/^['"]|['"]$/g, "");
    if (!apiKey) {
      throw new Error("XAI_API_KEY not configured");
    }

    const keyMeta = {
      keyLength: apiKey.length,
      keyPrefix: apiKey.slice(0, 4),
      looksLikeXaiKey: apiKey.startsWith("xai-"),
    };
    log("minting ephemeral token", keyMeta);

    const response = await fetch(XAI_CLIENT_SECRETS_URL, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ expires_after: { seconds: 300 } }),
    });

    const body = await response.text();
    if (!response.ok) {
      log("xAI rejected ephemeral-token request", {
        status: response.status,
        body: body.slice(0, 300),
        ...keyMeta,
      });
      // Surface upstream detail so curl can diagnose without dashboard logs.
      return new Response(
        JSON.stringify({
          error: "Unable to create Grok voice session",
          upstreamStatus: response.status,
          upstreamBody: body.slice(0, 500),
          ...keyMeta,
        }),
        {
          status: 502,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const secret = JSON.parse(body) as {
      value: string;
      expires_at: number;
    };
    log("issued ephemeral token", { expiresAt: secret.expires_at });

    return new Response(
      JSON.stringify({
        value: secret.value,
        expires_at: secret.expires_at,
        model: MODEL,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log("request failed", { message });
    return new Response(
      JSON.stringify({ error: message }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
