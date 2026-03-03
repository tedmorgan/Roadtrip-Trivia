-- Roadtrip Trivia — Supabase Database Schema
-- Handles: rate limiting, usage tracking, session history

-- Usage logs for cost tracking (PRD COST-02)
CREATE TABLE IF NOT EXISTS usage_logs (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id text NOT NULL,
    endpoint text NOT NULL,            -- 'generate-questions', 'grade-answer', 'challenge-answer'
    model text NOT NULL DEFAULT 'gpt-4o',
    prompt_tokens integer,
    completion_tokens integer,
    latency_ms integer,
    created_at timestamptz DEFAULT now()
);

CREATE INDEX idx_usage_logs_user ON usage_logs(user_id, created_at);
CREATE INDEX idx_usage_logs_endpoint ON usage_logs(endpoint, created_at);

-- Rate limits per account (PRD COST-05)
CREATE TABLE IF NOT EXISTS rate_limits (
    user_id text PRIMARY KEY,
    requests_today integer DEFAULT 0,
    requests_this_hour integer DEFAULT 0,
    last_request_at timestamptz DEFAULT now(),
    daily_reset_at timestamptz DEFAULT now(),
    hourly_reset_at timestamptz DEFAULT now(),
    is_blocked boolean DEFAULT false,
    block_reason text
);

-- Session history for analytics (PRD ANAL-001, ANAL-002)
CREATE TABLE IF NOT EXISTS sessions (
    id uuid PRIMARY KEY,
    user_id text NOT NULL,
    difficulty text NOT NULL,
    player_count integer NOT NULL,
    rounds_played integer DEFAULT 0,
    lightning_rounds_played integer DEFAULT 0,
    total_questions_answered integer DEFAULT 0,
    total_questions_correct integer DEFAULT 0,
    total_hints_used integer DEFAULT 0,
    total_challenges_used integer DEFAULT 0,
    total_challenges_overturned integer DEFAULT 0,
    duration_seconds integer,
    location_label text,
    is_complete boolean DEFAULT false,
    created_at timestamptz DEFAULT now(),
    completed_at timestamptz
);

CREATE INDEX idx_sessions_user ON sessions(user_id, created_at);

-- Row Level Security
ALTER TABLE usage_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE rate_limits ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;

-- Users can only see their own data
CREATE POLICY "Users see own usage" ON usage_logs
    FOR SELECT USING (user_id = auth.uid()::text);

CREATE POLICY "Users see own rate limits" ON rate_limits
    FOR SELECT USING (user_id = auth.uid()::text);

CREATE POLICY "Users see own sessions" ON sessions
    FOR SELECT USING (user_id = auth.uid()::text);

-- Service role can do everything (for edge functions)
CREATE POLICY "Service role full access usage" ON usage_logs
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role full access rate_limits" ON rate_limits
    FOR ALL USING (auth.role() = 'service_role');

CREATE POLICY "Service role full access sessions" ON sessions
    FOR ALL USING (auth.role() = 'service_role');
