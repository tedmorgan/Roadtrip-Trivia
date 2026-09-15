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

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(timestamp)] $*"; }

log "Deploying Roadtrip Trivia Edge Functions..."
echo ""

# Deploy each function
log "1/7 Deploying generate-questions..."
npx supabase functions deploy generate-questions --no-verify-jwt
log "    Done."

log "2/7 Deploying grade-answer..."
npx supabase functions deploy grade-answer --no-verify-jwt
log "    Done."

log "3/7 Deploying challenge-answer..."
npx supabase functions deploy challenge-answer --no-verify-jwt
log "    Done."

log "4/7 Deploying realtime-token..."
npx supabase functions deploy realtime-token --no-verify-jwt
log "    Done."

log "5/7 Deploying grok-token..."
npx supabase functions deploy grok-token --no-verify-jwt
log "    Done."

log "6/7 Deploying gemini-live-token (JWT required)..."
npx supabase functions deploy gemini-live-token
log "    Done."

log "7/7 Deploying gemini-question-batch (JWT required)..."
npx supabase functions deploy gemini-question-batch
log "    Done."

echo ""
log "All functions deployed successfully!"
echo ""
echo "Endpoints:"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/generate-questions"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/grade-answer"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/challenge-answer"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/realtime-token"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/grok-token"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/gemini-live-token"
echo "  POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/gemini-question-batch"
echo ""
echo "Make sure API keys are set:"
echo "  npx supabase secrets set OPENAI_API_KEY=sk-your-key-here"
echo "  npx supabase secrets set GEMINI_API_KEY=your-gemini-key-here"
echo "  npx supabase secrets set XAI_API_KEY=xai-your-key-here"
