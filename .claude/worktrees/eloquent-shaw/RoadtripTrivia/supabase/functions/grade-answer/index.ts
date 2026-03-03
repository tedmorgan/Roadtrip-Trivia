import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const GPT_MODEL = "gpt-4o";

interface GradeRequest {
  question: string;
  correctAnswer: string;
  playerAnswer: string;
  gradingRubric: string;
  difficulty: string;
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
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401 });
    }

    const body: GradeRequest = await req.json();
    const startTime = Date.now();

    // PRD PERF-01: target ≤ 5 second total grading latency
    const systemPrompt = `You are a trivia answer grader for a family car game.

Grade the player's answer against the correct answer using the provided rubric.

STRICTNESS LEVEL: ${body.difficulty}
- lenient: Accept phonetically similar, partial, or loosely related answers
- moderate: Key facts must be present, minor details can be off
- strict: Most specific details required, minor wording differences OK
- near-exact: Answer must be very close to the correct answer

GRADING RUBRIC: ${body.gradingRubric}

If you genuinely cannot determine if the answer is correct or incorrect, mark isUncertain as true.
Only mark uncertain if there's a real ambiguity — not just a close call.

Respond with ONLY valid JSON:
{
  "isCorrect": true/false,
  "isUncertain": true/false,
  "explanation": "Brief 1-sentence explanation of why correct/incorrect"
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
          {
            role: "user",
            content: `Question: ${body.question}\nCorrect answer: ${body.correctAnswer}\nPlayer's answer: ${body.playerAnswer}`,
          },
        ],
        temperature: 0.1, // Low temperature for consistent grading
        max_tokens: 200,
        response_format: { type: "json_object" },
      }),
    });

    const latencyMs = Date.now() - startTime;
    console.log(`grade-answer latency: ${latencyMs}ms`);

    if (!openaiResponse.ok) {
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

    let parsed;
    try {
      parsed = JSON.parse(content);
    } catch {
      return new Response(
        JSON.stringify({ error: "Malformed grading response" }),
        { status: 502 }
      );
    }

    return new Response(JSON.stringify(parsed), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("grade-answer error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500 }
    );
  }
});
