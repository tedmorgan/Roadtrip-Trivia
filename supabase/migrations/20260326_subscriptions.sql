-- Subscription & round balance tracking
-- Synced from StoreKit 2 on-device; authoritative for multi-device users.

CREATE TABLE IF NOT EXISTS subscriptions (
    id              UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Active subscription info (from StoreKit 2 / App Store Server Notifications)
    product_id              TEXT,                           -- e.g. 'com.nagrom.roadtrip.monthly'
    status                  TEXT DEFAULT 'none'             -- 'active', 'expired', 'cancelled', 'billing_retry', 'none'
        CHECK (status IN ('active', 'expired', 'cancelled', 'billing_retry', 'none')),
    original_transaction_id TEXT,                           -- Apple's original transaction ID
    current_period_start    TIMESTAMPTZ,
    current_period_end      TIMESTAMPTZ,

    -- Round balance
    purchased_rounds        INT DEFAULT 0,                  -- consumable round packs (never expire)
    subscription_rounds_used INT DEFAULT 0,                 -- rounds used this billing period
    free_round_used         BOOLEAN DEFAULT FALSE,          -- lifetime free round consumed

    -- Lifetime stats
    rounds_played_total     INT DEFAULT 0,
    total_amount_spent      NUMERIC(10,2) DEFAULT 0,        -- for analytics

    -- Timestamps
    updated_at              TIMESTAMPTZ DEFAULT NOW(),
    created_at              TIMESTAMPTZ DEFAULT NOW(),

    UNIQUE(user_id)
);

-- Index for looking up by Apple transaction ID (webhook reconciliation)
CREATE INDEX IF NOT EXISTS idx_subscriptions_transaction
    ON subscriptions(original_transaction_id)
    WHERE original_transaction_id IS NOT NULL;

-- Row Level Security
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can read own subscription"
    ON subscriptions FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can update own subscription"
    ON subscriptions FOR UPDATE
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own subscription"
    ON subscriptions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Service role (edge functions) has full access via default grant.

-- Auto-update the updated_at timestamp
CREATE OR REPLACE FUNCTION update_subscriptions_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER subscriptions_updated_at
    BEFORE UPDATE ON subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION update_subscriptions_timestamp();

-- Helper: upsert subscription state from App Store Server Notification
CREATE OR REPLACE FUNCTION upsert_subscription(
    p_user_id UUID,
    p_product_id TEXT,
    p_status TEXT,
    p_original_transaction_id TEXT,
    p_period_start TIMESTAMPTZ,
    p_period_end TIMESTAMPTZ
) RETURNS VOID AS $$
BEGIN
    INSERT INTO subscriptions (user_id, product_id, status, original_transaction_id, current_period_start, current_period_end)
    VALUES (p_user_id, p_product_id, p_status, p_original_transaction_id, p_period_start, p_period_end)
    ON CONFLICT (user_id) DO UPDATE SET
        product_id = EXCLUDED.product_id,
        status = EXCLUDED.status,
        original_transaction_id = EXCLUDED.original_transaction_id,
        current_period_start = EXCLUDED.current_period_start,
        current_period_end = EXCLUDED.current_period_end,
        -- Reset subscription rounds when a new period starts
        subscription_rounds_used = CASE
            WHEN subscriptions.current_period_start IS DISTINCT FROM EXCLUDED.current_period_start
            THEN 0
            ELSE subscriptions.subscription_rounds_used
        END;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
