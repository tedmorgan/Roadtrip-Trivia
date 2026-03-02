/**
 * challenge-answer Edge Function
 *
 * PRD Requirements:
 * - UC-20: Challenge Ruling — second-pass verification of a grading result
 * - CHAL-01: Voice command 'challenge' triggers re-grade (one per question, standard rounds only)
 * - The challenge uses a stricter "double check" instruction
 * - Must consider the question, canonical answer, acceptable variants, and the player's transcript
 */

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";
import { chatCompletion } from "../_shared/openai.ts";
import { checkRateLimit, extractUserId } from "../_shared/ratelimit.ts";

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
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Rate limiting (COST-05)
    const userId = extractUserId(req);
    if (userId) {
      const limit = await checkRateLimit(userId, "challenge");
      if (!limit.allowed) {
        return new Response(JSON.stringify({ error: limit.message }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 429,
        });
      }
    }
    const body: ChallengeRequest = await req.json();
    const {
      question,
      correctAnswer,
      playerAnswer,
      gradingRubric,
      difficulty,
      originalGrading,
    } = body;

    console.log(
      `[challenge-answer] Re-grading: "${playerAnswer}" vs "${correctAnswer}" (original: ${originalGrading})`
    );

    const systemPrompt = `You are the CHALLENGE JUDGE for "Roadtrip Trivia", a voice-first CarPlay trivia game.

A player has CHALLENGED a grading ruling. Your job is to perform a careful, independent second-pass review.

CONTEXT:
- The player's answer came from speech-to-text (STT), which commonly produces homophones, missing articles, slight misspellings, and number-word substitutions.
- The original grading ruled the answer as: ${originalGrading}.
- The player believes this ruling was wrong and has used their one-per-question challenge.

YOUR TASK:
Perform a THOROUGH, FAIR re-evaluation. Consider:
1. Could STT have mangled a correct answer into what was transcribed?
2. Is the player's answer a valid alternate name, abbreviation, or colloquial form of the correct answer?
3. Does the grading rubric list this as an acceptable variant?
4. Is there any reasonable interpretation where the player's answer is correct?

DIFFICULTY CONTEXT: ${difficulty}
- For "lenient"/"moderate" difficulties: give the player reasonable benefit of the doubt.
- For "strict"/"near-exact" difficulties: only overturn if the answer is genuinely correct despite the original ruling.

You MUST respond with valid JSON:
{
  "overturned": boolean,
  "explanation": "string — brief, conversational explanation suitable for TTS (1-2 sentences)"
}

RULES:
- Be fair but not a pushover. Only overturn if there's genuine merit.
- If the answer is clearly wrong, uphold the original ruling gracefully.
- Explanation should be conversational and TTS-friendly — no special characters.`;

    const userPrompt = `Question: ${question}
Correct answer: ${correctAnswer}
Player's spoken answer (from STT): "${playerAnswer}"
Grading rubric: ${gradingRubric}
Original ruling: ${originalGrading}

The player is challenging this ruling. Perform your independent review and decide: should the original ruling be overturned?`;

    const raw = await chatCompletion(
      [
        { role: "system", content: systemPrompt },
        { role: "user", content: userPrompt },
      ],
      {
        model: "gpt-4o-mini",
        temperature: 0.2, // Low temperature for consistent judging
        maxTokens: 300,
        responseFormat: { type: "json_object" },
      }
    );

    const parsed = JSON.parse(raw);
    const result = {
      overturned: Boolean(parsed.overturned),
      explanation: String(
        parsed.explanation ||
          (parsed.overturned
            ? "Challenge successful!"
            : "The original ruling stands.")
      ),
    };

    console.log(
      `[challenge-answer] Result: overturned=${result.overturned}`
    );

    return new Response(JSON.stringify(result), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error) {
    console.error("[challenge-answer] Error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});
