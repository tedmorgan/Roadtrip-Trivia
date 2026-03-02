// Shared OpenAI helper for all Edge Functions
// Reads OPENAI_API_KEY from Supabase secrets

const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");

if (!OPENAI_API_KEY) {
  console.error("OPENAI_API_KEY is not set in Supabase secrets");
}

export interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface OpenAIResponse {
  choices: Array<{
    message: {
      content: string;
    };
    finish_reason: string;
  }>;
  usage: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
}

/**
 * Call OpenAI Chat Completions API.
 * Uses gpt-4o-mini for cost efficiency (PRD COST-01).
 * Temperature tuned per use case.
 */
export async function chatCompletion(
  messages: ChatMessage[],
  options: {
    model?: string;
    temperature?: number;
    maxTokens?: number;
    responseFormat?: { type: string };
  } = {}
): Promise<string> {
  const {
    model = "gpt-4o-mini",
    temperature = 0.8,
    maxTokens = 2000,
    responseFormat,
  } = options;

  const body: Record<string, unknown> = {
    model,
    messages,
    temperature,
    max_tokens: maxTokens,
  };

  if (responseFormat) {
    body.response_format = responseFormat;
  }

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(
      `OpenAI API error ${response.status}: ${errorText}`
    );
  }

  const data: OpenAIResponse = await response.json();
  return data.choices[0].message.content;
}
