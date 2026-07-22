#!/bin/bash
# Deploy Roadtrip Trivia Supabase Edge Functions
#
# Prerequisites:
#   1. Install Supabase CLI: brew install supabase/tap/supabase
#   2. Login: supabase login
#   3. Link project: supabase link --project-ref kakhzbcuudkrrktkobjs
#   4. Set OpenAI key: supabase secrets set OPENAI_API_KEY=sk-your-key-here
#
# Usage: ./deploy.sh

set -e

echo "Deploying Roadtrip Trivia Edge Functions..."
echo ""

# Deploy each function
echo "1/4 Deploying generate-questions..."
npx supabase functions deploy generate-questions --no-verify-jwt
echo "    Done."

echo "2/4 Deploying grade-answer..."
npx supabase functions deploy grade-answer --no-verify-jwt
echo "    Done."

echo "3/4 Deploying challenge-answer..."
npx supabase functions deploy challenge-answer --no-verify-jwt
echo "    Done."

echo "4/5 Deploying realtime-token..."
npx supabase functions deploy realtime-token --no-verify-jwt
echo "    Done."

echo "5/5 Deploying gemini-token..."
npx supabase functions deploy gemini-token --no-verify-jwt
echo "    Done."

echo ""
echo "All functions deployed successfully!"
echo ""
echo "Endpoints:"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/generate-questions"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/grade-answer"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/challenge-answer"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/realtime-token"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/gemini-token"
echo ""
echo "Make sure API keys are set:"
echo "  npx supabase secrets set OPENAI_API_KEY=sk-your-key-here"
echo "  npx supabase secrets set GEMINI_API_KEY=your-gemini-key-here"
