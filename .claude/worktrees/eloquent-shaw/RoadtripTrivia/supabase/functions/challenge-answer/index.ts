import { serve } from "https://deno.land/std@0.177.0/http/server.ts";

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY")!;
const GPT_MODEL = "gpt-4o";

interface ChallengeRequest {
  question: string;
  correctAnswer: string;
  playerAnswer: string;
  gradingRubric: string;
  difficulty: string;
  originalGrading: string;
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

    const body: ChallengeRequest = await req.json();

    // PRD CHAL-01: second-pass GPT call with stricter "double check" instruction
    const systemPrompt = `You are a trivia answer grader performing a CHALLENGE REVIEW.

The player's answer was originally graded as INCORRECT, and the player is challenging this ruling.
You must DOUBLE CHECK the grading very carefully. Consider:
- Alternative phrasings that mean the same thing
- Partial credit scenarios
- Regional or cultural variations of the answer
- Whether the answer demonstrates genuine knowledge of the topic

Be fair but thorough. Only overturn if the player's answer genuinely demonstrates knowledge of the correct answer.

STRICTNESS LEVEL: ${body.difficulty}
GRADING RUBRIC: ${body.gradingRubric}

Respond with ONLY valid JSON:
{
  "overturned": true/false,
  "explanation": "Brief explanation of the challenge ruling"
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
            content: `Question: ${body.question}\nCorrect answer: ${body.correctAnswer}\nPlayer's answer: ${body.playerAnswer}\nOriginal ruling: ${body.originalGrading}\n\nShould this ruling be overturned?`,
          },
        ],
        temperature: 0.1,
        max_tokens: 200,
        response_format: { type: "json_object" },
      }),
    });

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
        JSON.stringify({ error: "Malformed challenge response" }),
        { status: 502 }
      );
    }

    return new Response(JSON.stringify(parsed), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("challenge-answer error:", error);
    return new Response(
      JSON.stringify({ error: "Internal server error" }),
      { status: 500 }
    );
  }
});
