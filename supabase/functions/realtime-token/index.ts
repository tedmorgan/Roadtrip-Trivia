import { corsHeaders } from "../_shared/cors.ts";

/// Mints an ephemeral client token for the OpenAI Realtime API.
/// The permanent OPENAI_API_KEY never leaves the server.
///
/// POST /realtime-token
/// Body: { "voice": "alloy" }   (optional, defaults to "alloy")
/// Returns: { "client_secret": "ek_...", "expires_at": "2026-..." }

Deno.serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const openaiApiKey = Deno.env.get("OPENAI_API_KEY");
    if (!openaiApiKey) {
      throw new Error("OPENAI_API_KEY not configured");
    }

    // Parse optional voice preference from request body
    let voice = "alloy";
    try {
      const body = await req.json();
      if (body.voice) {
        voice = body.voice;
      }
    } catch {
      // No body or invalid JSON — use defaults
    }

    // Request ephemeral session from OpenAI
    const response = await fetch("https://api.openai.com/v1/realtime/sessions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${openaiApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "gpt-realtime",
        voice: voice,
      }),
    });

    if (!response.ok) {
      const errorBody = await response.text();
      console.error(`OpenAI session creation failed: ${response.status} ${errorBody}`);
      return new Response(
        JSON.stringify({ error: "Failed to create realtime session", details: errorBody }),
        { status: response.status, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const session = await response.json();

    // Return the ephemeral client secret to the app
    return new Response(
      JSON.stringify({
        client_secret: session.client_secret?.value ?? session.client_secret,
        expires_at: session.expires_at,
        session_id: session.id,
        voice: voice,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );

  } catch (error) {
    console.error("realtime-token error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
