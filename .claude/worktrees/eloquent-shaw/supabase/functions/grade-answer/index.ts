/**
 * grade-answer Edge Function
 *
 * PRD Requirements:
 * - UC-14: Grade the answer and update score within latency targets
 * - PERF-01: Provide correct/incorrect within 5 seconds typical
 * - GRADE-01: Strictness scales by difficulty (Simple=lenient, Einstein=near-exact)
 * - GRADE-02: Close-enough in Simple; near-exact in Einstein (allow STT noise)
 * - GRADE-03: Tricky and Hard sit between Simple and Einstein in strictness
 * - CLAR-01/02: If uncertain, return isUncertain=true so app can ask for clarification
 * - MODE-01: Simple uses multiple choice — grading is straightforward letter matching
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { chatCompletion } from "../_shared/openai.ts";
import { checkRateLimit, extractUserId } from "../_shared/ratelimit.ts";

interface GradeRequest {
  question: string;
  correctAnswer: string;
  playerAnswer: string;
  gradingRubric: string;
  difficulty: string;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Rate limiting (COST-05)
    const userId = extractUserId(req);
    if (userId) {
      const limit = await checkRateLimit(userId, "grade");
      if (!limit.allowed) {
        return new Response(JSON.stringify({ error: limit.message }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 429,
        });
      }
    }

    const body: GradeRequest = await req.json();
    const { question, correctAnswer, playerAnswer, gradingRubric, difficulty } =
      body;

    console.log(
      `[grade-answer] Grading: "${playerAnswer}" vs "${correctAnswer}" (${difficulty} strictness)`
    );

    // For very obvious matches, skip GPT call entirely (cost savings)
    const quickResult = tryQuickGrade(playerAnswer, correctAnswer, difficulty);
    if (quickResult !== null) {
      console.log(`[grade-answer] Quick grade: ${quickResult.isCorrect}`);
      return new Response(JSON.stringify(quickResult), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Full GPT grading
    const systemPrompt = buildGradingPrompt(difficulty);
    const userPrompt = `Question: ${question}
Correct answer: ${correctAnswer}
Player's spoken answer: "${playerAnswer}"
Grading rubric: ${gradingRubric}

Grade this answer. Remember: the player's answer came from speech-to-text, so minor transcription errors (homophones, missing articles, slight misspellings) should be forgiven. However, conceptually wrong answers are wrong regardless of STT noise.

Respond with JSON only.`;

    const raw = await chatCompletion(
      [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      {
        model: "gpt-4o-mini",
        temperature: 0.1, // Low temperature for consistent grading
        maxTokens: 300,
        responseFormat: { type: "json_object" },
      }
    );

    const parsed = JSON.parse(raw);
    const result = {
      isCorrect: Boolean(parsed.isCorrect),
      isUncertain: Boolean(parsed.isUncertain || false),
      explanation: String(
        parsed.explanation || (parsed.isCorrect ? "Correct!" : "Incorrect.")
      ),
    };

    console.log(
      `[grade-answer] Result: correct=${result.isCorrect}, uncertain=${result.isUncertain}`
    );

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    console.error("[grade-answer] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});

/**
 * Try to grade without a GPT call for obvious cases.
 * Returns null if GPT is needed.
 */
function tryQuickGrade(
  playerAnswer: string,
  correctAnswer: string,
  difficulty: string
): { isCorrect: boolean; isUncertain: boolean; explanation: string } | null {
  const player = playerAnswer.toLowerCase().trim();
  const correct = correctAnswer.toLowerCase().trim();

  // Exact match — always correct
  if (player === correct) {
    return {
      isCorrect: true,
      isUncertain: false,
      explanation: "That's right!",
    };
  }

  // Multiple choice letter matching (Simple mode)
  if (difficulty === "lenient" || difficulty === "Simple") {
    const letterMatch = player.match(/^[abcd]$/i);
    const correctLetterMatch = correct.match(/^[abcd]$/i);
    if (letterMatch && correctLetterMatch) {
      const isCorrect =
        letterMatch[0].toLowerCase() === correctLetterMatch[0].toLowerCase();
      return {
        isCorrect,
        isUncertain: false,
        explanation: isCorrect
          ? "That's right!"
          : `The correct answer was ${correctAnswer}.`,
      };
    }
  }

  // Check if player answer contains the key word(s) of the correct answer
  const correctWords = correct.split(/\s+/).filter((w) => w.length > 3);
  const allKeyWordsPresent =
    correctWords.length > 0 &&
    correctWords.every((word) => player.includes(word));
  if (allKeyWordsPresent) {
    return {
      isCorrect: true,
      isUncertain: false,
      explanation: "That's right!",
    };
  }

  // Empty answer — always wrong
  if (player.length === 0) {
    return {
      isCorrect: false,
      isUncertain: false,
      explanation: `The correct answer was ${correctAnswer}.`,
    };
  }

  // Otherwise, need GPT
  return null;
}

function buildGradingPrompt(difficulty: string): string {
  const strictnessGuide = getStrictnessGuide(difficulty);

  return `You are the answer grader for "Roadtrip Trivia", a voice-first CarPlay trivia game.

Your job: determine if the player's spoken answer is correct.

IMPORTANT CONTEXT:
- The player's answer comes from on-device speech-to-text (STT).
- STT commonly produces: homophones ("their" vs "there"), missing articles ("a", "the"), slight misspellings, number words vs digits ("four" vs "4"), truncated words.
- These STT artifacts should NOT count against the player.

GRADING STRICTNESS: ${strictnessGuide}

You MUST respond with valid JSON matching this schema:
{
  "isCorrect": boolean,
  "isUncertain": boolean,
  "explanation": "string — brief, spoken-aloud-friendly explanation (1-2 sentences max)"
}

RULES:
- isUncertain should be true ONLY if you genuinely cannot determine if the answer is right or wrong (e.g., ambiguous phrasing, partially correct, could go either way). This triggers a clarification request.
- explanation should be conversational and suitable for TTS — no special characters, keep it brief.
- When incorrect, mention the correct answer in the explanation.
- When correct, give brief positive feedback.`;
}

function getStrictnessGuide(difficulty: string): string {
  switch (difficulty) {
    case "lenient":
      return `LENIENT (Simple mode): Accept close-enough answers generously. "Close enough" counts. Phonetic similarity counts. Partial answers that show knowledge count. The goal is fun, not precision.`;
    case "moderate":
      return `MODERATE (Tricky mode): Accept reasonable variants and STT noise, but the core answer must be conceptually correct. Wordplay answers that show genuine knowledge should be accepted. Reject clearly wrong answers.`;
    case "strict":
      return `STRICT (Hard mode): The answer must be substantively correct. Allow STT transcription artifacts but not conceptual errors. Partial answers are generally not enough — the player should demonstrate clear knowledge.`;
    case "near-exact":
      return `NEAR-EXACT (Einstein mode): The answer must be very precise. Allow only STT noise (homophones, minor transcription errors). Do NOT accept conceptual substitutes, vague answers, or "close enough" responses. If in doubt, mark incorrect.`;
    default:
      return getStrictnessGuide("moderate");
  }
}
