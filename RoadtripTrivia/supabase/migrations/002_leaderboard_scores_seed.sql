-- Roadtrip Trivia — Leaderboard table + demo seed data
-- Run in Supabase SQL Editor or via `supabase db push` after linking the project.
--
-- Ensures each period filter returns enough rows for the app (top 15 per tab):
--   • Today: played_at within the last ~2 hours
--   • This month: played_at on days since the 1st of the current month
--   • All time: older played_at + highest scores

-- ---------------------------------------------------------------------------
-- Table
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.leaderboard_scores (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    team_name text NOT NULL,
    score integer NOT NULL CHECK (score >= 0),
    played_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_leaderboard_scores_played_at
    ON public.leaderboard_scores (played_at DESC);

CREATE INDEX IF NOT EXISTS idx_leaderboard_scores_score
    ON public.leaderboard_scores (score DESC);

COMMENT ON TABLE public.leaderboard_scores IS 'Team scores for in-app leaderboards (day / month / all-time).';

-- ---------------------------------------------------------------------------
-- RLS (anon key used by the app for GET + POST)
-- ---------------------------------------------------------------------------
ALTER TABLE public.leaderboard_scores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "leaderboard_scores_select_public" ON public.leaderboard_scores;
CREATE POLICY "leaderboard_scores_select_public"
    ON public.leaderboard_scores
    FOR SELECT
    TO anon, authenticated
    USING (true);

DROP POLICY IF EXISTS "leaderboard_scores_insert_public" ON public.leaderboard_scores;
CREATE POLICY "leaderboard_scores_insert_public"
    ON public.leaderboard_scores
    FOR INSERT
    TO anon, authenticated
    WITH CHECK (true);

-- Optional: tighten INSERT later to authenticated users only.

-- ---------------------------------------------------------------------------
-- Seed: clear demo rows (optional — uncomment before re-seeding)
-- ---------------------------------------------------------------------------
-- DELETE FROM public.leaderboard_scores
-- WHERE team_name IN (
--     'Van Life Vikings','Mile Marker Mafia','Rest Stop Rockstars','GPS Gone Wild',
--     'Backseat Brainiacs','Cruise Control Crew','Highway Hypothesis','Toll Road Titans',
--     'Scenic Route Squad','Road Trip Regents','Interstate Imps','Dashboard Debaters',
--     'Waffle House Winners','Trunk Treasures','Shoulder Lane Legends',
--     'Pit Stop PhDs','Merge Lane Masterminds','Carpool Champions',
--     'Neon Nomads','Desert Drifters','Coastal Coders','Mountain Mindbenders',
--     'Prairie Puzzlers','Bayou Brain Trust','Sunset Scholars','Harbor Hotshots',
--     'Summit Seekers','Canyon Crushers','Delta Drivers','Plateau Players',
--     'Evergreen Experts','Tundra Trivia','Aurora Arguers','Fjord Fanatics',
--     'Glacier Guessers','Volcano Victors',
--     'Legacy Legends','Hall of Highway Fame','Century Cruisers','Founding Roadsters',
--     'Original Outlaws','Mythic Motorists','Eternal Engines','Dynasty Drifters',
--     'Championship Caravan','Golden Guardrails','Platinum Parkway','Diamond Distance',
--     'Sapphire Skylines','Ruby Roadsters','Obsidian Odyssey','Vintage Voyagers',
--     'Horizon Holdouts','Atlas Answerers'
-- );

-- ---------------------------------------------------------------------------
-- SAMPLE DATA — explicit team_name + score on every line (18 rows per bucket)
--
-- TODAY        → recent played_at (Today tab)
-- THIS MONTH   → same calendar month, not all “last 2 hours” (This Month tab)
-- ALL TIME     → older dates + highest scores (All Time tab)
-- ---------------------------------------------------------------------------

-- --- Today ---
INSERT INTO public.leaderboard_scores (team_name, score, played_at) VALUES
    ('Van Life Vikings',        4820, now() - interval '12 minutes'),
    ('Mile Marker Mafia',       4755, now() - interval '22 minutes'),
    ('Rest Stop Rockstars',     4688, now() - interval '35 minutes'),
    ('GPS Gone Wild',           4610, now() - interval '41 minutes'),
    ('Backseat Brainiacs',      4544, now() - interval '48 minutes'),
    ('Cruise Control Crew',     4490, now() - interval '55 minutes'),
    ('Highway Hypothesis',      4425, now() - interval '63 minutes'),
    ('Toll Road Titans',        4360, now() - interval '71 minutes'),
    ('Scenic Route Squad',      4295, now() - interval '78 minutes'),
    ('Road Trip Regents',       4230, now() - interval '85 minutes'),
    ('Interstate Imps',         4165, now() - interval '92 minutes'),
    ('Dashboard Debaters',      4100, now() - interval '99 minutes'),
    ('Waffle House Winners',    4035, now() - interval '106 minutes'),
    ('Trunk Treasures',         3970, now() - interval '113 minutes'),
    ('Shoulder Lane Legends',   3905, now() - interval '118 minutes'),
    ('Pit Stop PhDs',           3840, now() - interval '124 minutes'),
    ('Merge Lane Masterminds',  3775, now() - interval '129 minutes'),
    ('Carpool Champions',       3710, now() - interval '135 minutes');

-- --- This month ---
INSERT INTO public.leaderboard_scores (team_name, score, played_at) VALUES
    ('Neon Nomads',             22150, date_trunc('month', now()) + interval '1 day 4 hours'),
    ('Desert Drifters',         21880, date_trunc('month', now()) + interval '2 days 9 hours'),
    ('Coastal Coders',          21620, date_trunc('month', now()) + interval '3 days 2 hours'),
    ('Mountain Mindbenders',    21390, date_trunc('month', now()) + interval '4 days 15 hours'),
    ('Prairie Puzzlers',        21140, date_trunc('month', now()) + interval '5 days 6 hours'),
    ('Bayou Brain Trust',       20910, date_trunc('month', now()) + interval '6 days 11 hours'),
    ('Sunset Scholars',         20670, date_trunc('month', now()) + interval '7 days 3 hours'),
    ('Harbor Hotshots',         20440, date_trunc('month', now()) + interval '8 days 18 hours'),
    ('Summit Seekers',          20200, date_trunc('month', now()) + interval '9 days 7 hours'),
    ('Canyon Crushers',         19960, date_trunc('month', now()) + interval '10 days 12 hours'),
    ('Delta Drivers',           19730, date_trunc('month', now()) + interval '11 days 1 hour'),
    ('Plateau Players',         19490, date_trunc('month', now()) + interval '12 days 20 hours'),
    ('Evergreen Experts',       19250, date_trunc('month', now()) + interval '13 days 5 hours'),
    ('Tundra Trivia',           19020, date_trunc('month', now()) + interval '14 days 14 hours'),
    ('Aurora Arguers',          18790, date_trunc('month', now()) + interval '15 days 8 hours'),
    ('Fjord Fanatics',          18550, date_trunc('month', now()) + interval '16 days 22 hours'),
    ('Glacier Guessers',        18320, date_trunc('month', now()) + interval '17 days 10 hours'),
    ('Volcano Victors',         18090, date_trunc('month', now()) + interval '18 days 16 hours');

-- --- All time ---
INSERT INTO public.leaderboard_scores (team_name, score, played_at) VALUES
    ('Legacy Legends',          98500, now() - interval '400 days 3 hours'),
    ('Hall of Highway Fame',    97200, now() - interval '380 days 8 hours'),
    ('Century Cruisers',        95800, now() - interval '350 days 2 hours'),
    ('Founding Roadsters',      94100, now() - interval '310 days 19 hours'),
    ('Original Outlaws',        92600, now() - interval '290 days 4 hours'),
    ('Mythic Motorists',        91200, now() - interval '260 days 11 hours'),
    ('Eternal Engines',         89800, now() - interval '240 days 6 hours'),
    ('Dynasty Drifters',        88400, now() - interval '220 days 20 hours'),
    ('Championship Caravan',    87100, now() - interval '200 days 9 hours'),
    ('Golden Guardrails',       85700, now() - interval '185 days 14 hours'),
    ('Platinum Parkway',        84300, now() - interval '170 days 7 hours'),
    ('Diamond Distance',        82900, now() - interval '155 days 21 hours'),
    ('Sapphire Skylines',       81500, now() - interval '140 days 5 hours'),
    ('Ruby Roadsters',          80100, now() - interval '125 days 16 hours'),
    ('Obsidian Odyssey',        78700, now() - interval '110 days 2 hours'),
    ('Vintage Voyagers',        77300, now() - interval '95 days 13 hours'),
    ('Horizon Holdouts',        75900, now() - interval '85 days 8 hours'),
    ('Atlas Answerers',         74500, now() - interval '75 days 18 hours');

-- If "Today" is empty on a phone (local midnight vs DB timezone), bump a few rows:
-- UPDATE public.leaderboard_scores SET played_at = now() - (random() * interval '2 hours')
-- WHERE team_name IN ('Van Life Vikings','Mile Marker Mafia','Rest Stop Rockstars');
