/**
 * generate-questions Edge Function
 *
 * PRD Requirements:
 * - COST-01: One GPT call per standard round generates full payload
 *   (category, 5 questions, answers, hints, grading rubrics)
 * - LOC-02: Only human-readable location label, no coordinates
 * - LOC-05: Label format: 'Near {town}, {state} ({major city} area)'
 * - LOC-03: 20-mile conceptual scope; fallback to broader region if quality low
 * - MODE-01: Simple = multiple choice (A/B/C/D)
 * - MODE-02: Tricky/Hard/Einstein = free-response spoken answers
 * - CAT-01: GPT selects category per round; announce at round start
 * - GAME-01: Standard round is exactly 5 questions
 * - GRADE-02: Locality specificity scales by difficulty
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { chatCompletion } from "../_shared/openai.ts";
import { checkRateLimit, extractUserId } from "../_shared/ratelimit.ts";

interface GenerateRequest {
  locationLabel: string;
  difficulty: string;
  ageBands: string[];
  roundNumber: number;
  excludeCategories: string[];
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Rate limiting (COST-05)
    const userId = extractUserId(req);
    if (userId) {
      const limit = await checkRateLimit(userId, "generate");
      if (!limit.allowed) {
        return new Response(JSON.stringify({ error: limit.message }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 429,
        });
      }
    }

    const body: GenerateRequest = await req.json();
    const {
      locationLabel,
      difficulty,
      ageBands,
      roundNumber,
      excludeCategories,
    } = body;

    console.log(
      `[generate-questions] Round ${roundNumber}, difficulty: ${difficulty}, location: ${locationLabel}`
    );

    // Build the system prompt per PRD requirements
    const systemPrompt = buildSystemPrompt(difficulty, ageBands, locationLabel, excludeCategories);
    const userPrompt = buildUserPrompt(difficulty, locationLabel, roundNumber);

    const raw = await chatCompletion(
      [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      {
        temperature: 0.9, // High creativity for varied questions
        maxTokens: 2500,
        responseFormat: { type: "json_object" },
      }
    );

    // Parse and validate the response
    const parsed = JSON.parse(raw);
    const validated = validateResponse(parsed, difficulty);

    console.log(
      `[generate-questions] Generated category: "${validated.category}" with ${validated.questions.length} questions`
    );

    return new Response(JSON.stringify(validated), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    console.error("[generate-questions] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});

function buildSystemPrompt(
  difficulty: string,
  ageBands: string[],
  locationLabel: string,
  excludeCategories: string[]
): string {
  const difficultyConfig = getDifficultyConfig(difficulty);
  const ageContext = ageBands.join(", ");
  const excludeClause =
    excludeCategories.length > 0
      ? `Do NOT use any of these categories: ${excludeCategories.join(", ")}.`
      : "";

  return `You are the question writer for "Roadtrip Trivia", a voice-first CarPlay trivia game for families and groups on road trips.

Your job: generate exactly ONE category and exactly 5 trivia questions for a single round.

AUDIENCE: ${ageContext}. Tailor language complexity and cultural references accordingly.
${ageBands.some((b) => b.includes("Kids")) ? "Keep content family-friendly and age-appropriate for children." : ""}

DIFFICULTY: ${difficulty}
- Answer format: ${difficultyConfig.answerFormat}
- Location specificity: ${difficultyConfig.localityDesc}
- Grading will be: ${difficultyConfig.gradingDesc}
${difficultyConfig.notes}

LOCATION CONTEXT: The players are near "${locationLabel}".
- For Simple/Tricky: use broad regional flavor (state, region, nearby landmarks) but questions don't need to be exclusively local.
- For Hard/Einstein: make questions more specifically tied to the area within ~20 miles when possible.
- If the location is generic ("somewhere in the United States"), use general American trivia.

${excludeClause}

RESPONSE FORMAT: You MUST respond with valid JSON matching this exact schema:
{
  "category": "string — a fun, specific category name (e.g., 'California Gold Rush', 'Space Exploration', 'Movie Villains')",
  "questions": [
    {
      "text": "string — the question text, written to be read aloud clearly",
      "correctAnswer": "string — the canonical correct answer",
      "hint": "string — one helpful hint that narrows it down without giving it away",
      "gradingRubric": "string — instructions for the grader: list acceptable alternate answers, common misspellings, what to reject"${
        difficultyConfig.includeMultipleChoice
          ? ',\n      "multipleChoiceOptions": ["string — correct answer", "string — plausible wrong A", "string — plausible wrong B", "string — plausible wrong C"]'
          : ""
      }
    }
  ]
}

IMPORTANT RULES:
- Exactly 5 questions, no more, no less.
- Questions must be factually accurate.
- Hints should be genuinely helpful but not give away the answer.
- Grading rubrics should list 2-4 acceptable answer variants and note what to reject.
- Questions should be answerable by voice — avoid questions requiring visual aids.
- Keep question text concise (under 30 words) so TTS reads them quickly.
${difficultyConfig.includeMultipleChoice ? "- multipleChoiceOptions must contain exactly 4 options, shuffled so the correct answer is not always first." : "- Do NOT include multipleChoiceOptions for this difficulty level."}`;
}

function buildUserPrompt(
  difficulty: string,
  locationLabel: string,
  roundNumber: number
): string {
  return `Generate round ${roundNumber} of trivia. Difficulty: ${difficulty}. Players are near: ${locationLabel}. Pick an interesting category and create 5 questions. Return valid JSON only.`;
}

interface DifficultyConfig {
  answerFormat: string;
  localityDesc: string;
  gradingDesc: string;
  notes: string;
  includeMultipleChoice: boolean;
}

function getDifficultyConfig(difficulty: string): DifficultyConfig {
  switch (difficulty.toLowerCase()) {
    case "simple":
      return {
        answerFormat: "Multiple choice (A/B/C/D)",
        localityDesc:
          "Broad area (region/state) with light local flavor",
        gradingDesc: 'Lenient ("close enough")',
        notes:
          "Designed for mixed ages and quick play. Questions should be fun and accessible.",
        includeMultipleChoice: true,
      };
    case "tricky":
      return {
        answerFormat: "Free-response (spoken voice answer)",
        localityDesc:
          "Mix of broad and some local (major landmarks/towns)",
        gradingDesc: "Moderate — allow wordplay and misdirection, still family-friendly",
        notes:
          "More wordplay and misdirection. Still family-friendly but more challenging.",
        includeMultipleChoice: false,
      };
    case "hard":
      return {
        answerFormat: "Free-response (spoken voice answer)",
        localityDesc:
          "More local, within ~20 miles when feasible",
        gradingDesc: "Strict-ish — fewer giveaways, relies on good question generation",
        notes:
          "Questions should require genuine knowledge. Fewer obvious hints.",
        includeMultipleChoice: false,
      };
    case "einstein":
      return {
        answerFormat: "Free-response (spoken voice answer)",
        localityDesc:
          "Aggressively local/niche (fallback to broader if needed)",
        gradingDesc:
          'Near-exact — allow STT noise but not conceptual substitutes, no "close enough"',
        notes:
          'The hardest level. Deep-cut trivia. Challenge flow is available for disputes. Do not accept "close enough" answers.',
        includeMultipleChoice: false,
      };
    default:
      return getDifficultyConfig("tricky");
  }
}

interface QuestionResponse {
  category: string;
  questions: Array<{
    text: string;
    correctAnswer: string;
    hint: string;
    gradingRubric: string;
    multipleChoiceOptions?: string[];
  }>;
}

function validateResponse(
  parsed: Record<string, unknown>,
  difficulty: string
): QuestionResponse {
  if (!parsed.category || typeof parsed.category !== "string") {
    throw new Error("Response missing valid 'category' field");
  }

  if (!Array.isArray(parsed.questions) || parsed.questions.length !== 5) {
    throw new Error(
      `Expected exactly 5 questions, got ${
        Array.isArray(parsed.questions) ? parsed.questions.length : 0
      }`
    );
  }

  const questions = (parsed.questions as Record<string, unknown>[]).map(
    (q, i) => {
      if (!q.text || !q.correctAnswer || !q.hint || !q.gradingRubric) {
        throw new Error(`Question ${i + 1} missing required fields`);
      }

      const result: QuestionResponse["questions"][0] = {
        text: String(q.text),
        correctAnswer: String(q.correctAnswer),
        hint: String(q.hint),
        gradingRubric: String(q.gradingRubric),
      };

      // Include multipleChoiceOptions only for Simple difficulty
      if (
        difficulty.toLowerCase() === "simple" &&
        Array.isArray(q.multipleChoiceOptions) &&
        q.multipleChoiceOptions.length === 4
      ) {
        result.multipleChoiceOptions = q.multipleChoiceOptions.map(String);
      }

      return result;
    }
  );

  return {
    category: String(parsed.category),
    questions,
  };
}
