import { corsHeaders } from "../_shared/cors.ts";

/// Returns a Gemini API key for the client to use with the Live API WebSocket.
/// The permanent GEMINI_API_KEY never leaves the server in production;
/// for now, this edge function passes the key so the iOS client can connect
/// directly to the Gemini Live WebSocket endpoint.
///
/// POST /gemini-token
/// Returns: { "api_key": "AI...", "model": "gemini-3.1-flash-live-preview" }

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const geminiApiKey = Deno.env.get("GEMINI_API_KEY");
    if (!geminiApiKey) {
      throw new Error("GEMINI_API_KEY not configured");
    }

    return new Response(
      JSON.stringify({
        api_key: geminiApiKey,
        model: "gemini-3.1-flash-live-preview",
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("gemini-token error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
