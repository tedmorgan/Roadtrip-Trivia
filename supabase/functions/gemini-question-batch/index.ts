import { corsHeaders } from "../_shared/cors.ts";
import { checkRateLimit, extractUserId } from "../_shared/ratelimit.ts";

const GEMINI_MODEL = "gemini-3.1-flash-lite";
const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta";

interface BatchRequest {
  location: string;
  difficulty: string;
  ageBands: string[];
  questionHistory: string[];
  usedCategories: string[];
  startingRound: number;
}

function log(message: string, detail?: unknown) {
  const timestamp = new Date().toISOString();
  if (detail === undefined) {
    console.log(`[${timestamp}] gemini-question-batch: ${message}`);
  } else {
    console.log(`[${timestamp}] gemini-question-batch: ${message}`, detail);
  }
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function difficultyRules(difficulty: string): string {
  switch (difficulty.toLowerCase()) {
    case "simple":
      return "Multiple choice with 4 options. Family-friendly, lenient. Include options as [\"A: ...\", \"B: ...\", \"C: ...\", \"D: ...\"]. correctAnswer is just the letter.";
    case "tricky":
      return "Multiple choice with 4 options. Include wordplay and misdirection. Include options as [\"A: ...\", \"B: ...\", \"C: ...\", \"D: ...\"]. correctAnswer is just the letter.";
    case "wicked_hard":
      return "Free response only. Genuinely challenging. Set options to null. correctAnswer is the answer text.";
    case "einstein":
      return "Free response only. Expert-level. Set options to null. correctAnswer is the answer text.";
    default:
      return "Multiple choice with 4 options. Include options as [\"A: ...\", \"B: ...\", \"C: ...\", \"D: ...\"]. correctAnswer is just the letter.";
  }
}

function buildPrompt(request: BatchRequest): string {
  const startingRound = request.startingRound;
  const lightningRound = Math.floor((startingRound + 4) / 5) * 5;
  const roundDescriptions: string[] = [];
  for (let round = startingRound; round <= startingRound + 4; round += 1) {
    roundDescriptions.push(
      round === lightningRound
        ? `Round ${round}: 10 questions (LIGHTNING — shorter, faster pacing, isLightning=true)`
        : `Round ${round}: 5 questions (standard, isLightning=false)`,
    );
  }

  const avoidedCategories = request.usedCategories.length
    ? request.usedCategories.join(", ")
    : "None";
  const history = request.questionHistory.length
    ? `- ${request.questionHistory.join("\n- ")}`
    : "None — first game.";

  return `Generate trivia questions for a voice-based road trip game.

LOCATION: ${request.location}
DIFFICULTY: ${request.difficulty}
PLAYER AGES: ${request.ageBands.join(", ")}

Generate exactly 5 rounds:
${roundDescriptions.map((line) => `- ${line}`).join("\n")}

CATEGORY RULES:
- Choose 5 DIFFERENT broad categories from: Science & Nature, History, Geography, Sports, Entertainment, Food & Drink, Art & Literature, Music, Pop Culture, Animals & Wildlife, Movies & TV, World Cultures, Technology, Mythology & Legends.
- Every question in a round MUST be from that round's single category.
- Do NOT reuse these already-used categories: ${avoidedCategories}

LOCATION RULES:
- The player is currently near: ${request.location}.
- At least 1 question in EACH standard round MUST relate to the player's location, state, or region.
- For the lightning round, at least 2 of the 10 questions should be location-related.

DIFFICULTY RULES:
${difficultyRules(request.difficulty)}
For multiple choice, randomize which letter (A-D) is correct for each question.

BANNED TOPICS — do not generate questions covering these subjects:
${history}
Every question must be on a completely different topic from the banned list.

Return ONLY valid JSON in this exact shape:
{
  "rounds": [{
    "roundNumber": ${startingRound},
    "category": "Category Name",
    "isLightning": false,
    "questions": [{
      "questionText": "Full question text here?",
      "options": ["A: First", "B: Second", "C: Third", "D: Fourth"],
      "correctAnswer": "B"
    }]
  }]
}`;
}

function parseGeminiJSON(raw: string): unknown {
  let text = raw.trim();
  if (text.startsWith("```")) {
    text = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "");
  }
  const firstBrace = text.indexOf("{");
  const lastBrace = text.lastIndexOf("}");
  if (firstBrace >= 0 && lastBrace > firstBrace) {
    text = text.slice(firstBrace, lastBrace + 1);
  }
  return JSON.parse(text);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

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

    const body = await req.json() as Partial<BatchRequest>;
    const request: BatchRequest = {
      location: String(body.location ?? "").slice(0, 200),
      difficulty: String(body.difficulty ?? ""),
      ageBands: Array.isArray(body.ageBands)
        ? body.ageBands.map(String).slice(0, 8)
        : [],
      questionHistory: Array.isArray(body.questionHistory)
        ? body.questionHistory.map(String).slice(-250)
        : [],
      usedCategories: Array.isArray(body.usedCategories)
        ? body.usedCategories.map(String).slice(-50)
        : [],
      startingRound: Math.max(1, Math.floor(Number(body.startingRound) || 1)),
    };
    if (!request.location || !request.difficulty || request.ageBands.length === 0) {
      return jsonResponse({ error: "Missing required batch configuration" }, 400);
    }

    const rateLimit = await checkRateLimit(userId, "generate");
    if (!rateLimit.allowed) {
      return jsonResponse({ error: rateLimit.message }, 429);
    }

    const prompt = buildPrompt(request);
    log("requesting question batch", {
      userId,
      startingRound: request.startingRound,
      historyCount: request.questionHistory.length,
      promptChars: prompt.length,
    });

    const response = await fetch(
      `${GEMINI_BASE}/models/${GEMINI_MODEL}:generateContent?key=${apiKey}`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          contents: [{ parts: [{ text: prompt }] }],
          generationConfig: {
            responseMimeType: "application/json",
            temperature: 1.0,
          },
        }),
      },
    );
    const responseText = await response.text();
    if (!response.ok) {
      log("Gemini batch request failed", {
        status: response.status,
        body: responseText.slice(0, 500),
      });
      return jsonResponse({ error: "Question generation failed" }, 502);
    }

    const gemini = JSON.parse(responseText) as {
      candidates?: Array<{ content?: { parts?: Array<{ text?: string }> } }>;
      usageMetadata?: Record<string, unknown>;
    };
    const generated = gemini.candidates?.[0]?.content?.parts?.[0]?.text;
    if (!generated) {
      throw new Error("Gemini returned an empty batch");
    }
    const batch = parseGeminiJSON(generated) as {
      rounds?: Array<{ questions?: unknown[] }>;
    };
    if (!Array.isArray(batch.rounds) || batch.rounds.length !== 5) {
      throw new Error("Gemini returned an invalid round count");
    }
    for (let offset = 0; offset < 5; offset += 1) {
      const expectedRound = request.startingRound + offset;
      const round = batch.rounds[offset] as {
        roundNumber?: number;
        isLightning?: boolean;
        questions?: unknown[];
      };
      const expectedQuestions = expectedRound % 5 === 0 ? 10 : 5;
      if (
        round.roundNumber !== expectedRound ||
        round.isLightning !== (expectedRound % 5 === 0) ||
        round.questions?.length !== expectedQuestions
      ) {
        throw new Error(`Gemini returned an invalid Round ${expectedRound}`);
      }
    }

    log("question batch generated", {
      userId,
      rounds: batch.rounds.length,
      totalQuestions: batch.rounds.reduce(
        (total, round) => total + (round.questions?.length ?? 0),
        0,
      ),
      usageMetadata: gemini.usageMetadata ?? {},
    });
    return jsonResponse(batch);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log("request failed", { message });
    return jsonResponse({ error: message }, 500);
  }
});
