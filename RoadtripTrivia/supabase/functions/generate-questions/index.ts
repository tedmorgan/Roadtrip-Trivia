import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Per PRD COST-01: one GPT call per round, cap rerolls at 2
const MAX_REROLLS_PER_ROUND = 2;
const GPT_MODEL = "gpt-4o";

interface GenerateRequest {
  locationLabel: string;
  difficulty: string;
  ageBands: string[];
  roundNumber: number;
  excludeCategories: string[];
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST",
        "Access-Control-Allow-Headers": "authorization, content-type",
      },
    });
  }

  try {
    // Verify auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

    // Parse request
    const body: GenerateRequest = await req.json();

    // Rate limiting check (per PRD COST-05)
    // TODO: Check against rate_limits table for this user

    // Build GPT prompt
    // Per PRD: NEVER include raw coordinates. Only the human-readable location label.
    // Per PRD: Kid-safe content constraints baked into prompt.
    const systemPrompt = `You are a trivia question generator for a family-friendly car game called Roadtrip Trivia.

RULES:
- Generate exactly 5 trivia questions related to the location and category
- All content must be appropriate for ALL ages, including young children
- NEVER generate questions about violence, drugs, alcohol, sexual content, or anything inappropriate
- Questions should be fun, educational, and engaging for a car ride
- Vary question types: history, geography, culture, nature, food, sports, science
- Each question needs: the question text, correct answer, one hint, and a grading rubric
- The grading rubric describes how strictly to evaluate answers at this difficulty level

DIFFICULTY: ${body.difficulty}
- Simple: Multiple choice (A/B/C/D). Lenient grading — accept close answers.
- Tricky: Free response. Moderate grading — key facts must be present.
- Hard: Free response. Strict grading — specific details required.
- Einstein: Free response. Near-exact grading — precise answer expected.

LOCATION: ${body.locationLabel}
AGE GROUPS: ${body.ageBands.join(", ")}
ROUND NUMBER: ${body.roundNumber}
${body.excludeCategories.length > 0 ? `AVOID THESE CATEGORIES (used recently): ${body.excludeCategories.join(", ")}` : ""}

Respond with ONLY valid JSON in this exact format:
{
  "category": "Category Name",
  "questions": [
    {
      "text": "Question text?",
      "correctAnswer": "The correct answer",
      "hint": "A helpful hint",
      "gradingRubric": "How to grade this answer at ${body.difficulty} difficulty",
      ${body.difficulty === "Simple" ? '"multipleChoiceOptions": ["Option A", "Option B", "Option C", "Option D"],' : ""}
    }
  ]
}`;

    const openaiResponse = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: GPT_MODEL,
        messages: [
          { role: "system", content: systemPrompt },
          { role: "user", content: `Generate 5 ${body.difficulty} trivia questions about the area: ${body.locationLabel}` },
        ],
        temperature: 0.8,
        max_tokens: 2000,
        response_format: { type: "json_object" },
      }),
    });

    if (!openaiResponse.ok) {
      const errorText = await openaiResponse.text();
      console.error("OpenAI API error:", errorText);
      return new Response(
        JSON.stringify({ error: "GPT service unavailable" }),
        { status: 502 }
      );
    }

    const gptResult = await openaiResponse.json();
    const content = gptResult.choices[0]?.message?.content;

    if (!content) {
      return new Response(
        JSON.stringify({ error: "Empty GPT response" }),
        { status: 502 }
      );
    }

    // Parse and validate GPT JSON response (PRD GPT-004)
    let parsed;
    try {
      parsed = JSON.parse(content);
    } catch {
      console.error("Failed to parse GPT response:", content);
      return new Response(
        JSON.stringify({ error: "Malformed GPT response" }),
        { status: 502 }
      );
    }

    // Validate structure
    if (!parsed.category || !Array.isArray(parsed.questions) || parsed.questions.length === 0) {
      return new Response(
        JSON.stringify({ error: "Invalid question structure" }),
        { status: 502 }
      );
    }

    // Log usage for cost tracking (PRD COST-02)
    // TODO: Insert into usage_logs table

    return new Response(JSON.stringify(parsed), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("generate-questions error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500 }
    );
  }
});
