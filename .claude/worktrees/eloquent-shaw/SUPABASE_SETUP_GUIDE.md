# Roadtrip Trivia — Supabase Setup Guide

Complete these steps to finish the backend setup.

---

## Step 1: Apply the Database Migration

1. Go to your **Supabase Dashboard** → **SQL Editor**
2. Open the file `supabase/migrations/20260228_initial_schema.sql` from the project
3. Paste the entire contents into the SQL Editor
4. Click **Run**

This creates: `profiles`, `session_history`, `rate_limits` tables, RLS policies, triggers, and helper functions.

**Verify**: Go to **Table Editor** — you should see all three tables listed.

---

## Step 2: Get Your Anon Key

1. Go to **Supabase Dashboard** → **Settings** → **API**
2. Copy the **anon / public** key (starts with `eyJ...`)
3. Open `RoadtripTrivia/Services/Auth/AuthService.swift`
4. Replace `"YOUR_SUPABASE_ANON_KEY"` on line 23 with your actual key

> The anon key is safe to embed in the app — Row Level Security enforces data access server-side.

---

## Step 3: Enable Auth Providers

Go to **Supabase Dashboard** → **Authentication** → **Providers**:

### Sign in with Apple (Primary — AUTH-01)
1. Toggle **Apple** to enabled
2. You need an **Apple Services ID** and **Secret Key** from Apple Developer:
   - Go to developer.apple.com → **Certificates, Identifiers & Profiles**
   - Create a **Services ID** (e.g., `com.nagrom.roadtrip.auth`)
   - Configure it with your app's **Return URL**: `https://kakhzbcuudkrrktkobjs.supabase.co/auth/v1/callback`
   - Create a **Key** with "Sign in with Apple" enabled, download the `.p8` file
3. Enter in Supabase: Services ID, Team ID, Key ID, and paste the `.p8` private key contents

### Email / Password (AUTH-01)
1. Toggle **Email** to enabled (likely already on by default)
2. Under settings:
   - **Enable email confirmations**: your choice (recommended ON for production, OFF for testing)
   - **Minimum password length**: 8 characters recommended

### Magic Link (AUTH-01)
1. Magic Link uses the same **Email** provider — it's already enabled if Email is on
2. No additional configuration needed

### Google (AUTH-01, optional)
1. Toggle **Google** to enabled
2. Create OAuth credentials at console.cloud.google.com:
   - **OAuth Client ID** (iOS type) with your app's bundle ID
   - **OAuth Client ID** (Web type) for Supabase callback
3. Enter the Web Client ID and Secret in Supabase
4. Authorized redirect URI: `https://kakhzbcuudkrrktkobjs.supabase.co/auth/v1/callback`

### Facebook (AUTH-01, optional)
1. Toggle **Facebook** to enabled
2. Create an app at developers.facebook.com
3. Add **Facebook Login** product
4. Enter App ID and App Secret in Supabase
5. Valid OAuth Redirect URI: `https://kakhzbcuudkrrktkobjs.supabase.co/auth/v1/callback`

---

## Step 4: Set OpenAI Secret & Deploy Edge Functions

```bash
cd supabase

# Set the OpenAI API key (if not already done)
npx supabase secrets set OPENAI_API_KEY=sk-your-key-here --project-ref kakhzbcuudkrrktkobjs

# Deploy all three Edge Functions
chmod +x deploy.sh
./deploy.sh
```

**Verify**: Go to **Supabase Dashboard** → **Edge Functions** — you should see `generate-questions`, `grade-answer`, and `challenge-answer` listed.

---

## Step 5: Test the Setup

1. **Test Edge Function** (from terminal):
   ```bash
   curl -X POST https://kakhzbcuudkrrktkobjs.supabase.co/functions/v1/generate-questions \
     -H "Content-Type: application/json" \
     -d '{"locationLabel":"Near Austin, TX","difficulty":"Simple","ageBands":["Adults (18+)"],"roundNumber":1,"excludeCategories":[]}'
   ```
   You should get back a JSON response with a category and 5 questions.

2. **Test on Device**: Build to a real device (not simulator) — it will use the live Supabase Edge Functions instead of mock data.

3. **Test Auth**: The `#if DEBUG` block auto-authenticates in debug builds. For a real auth test, build in Release mode or remove the DEBUG block temporarily.

---

## Quick Reference

| Item | Value |
|------|-------|
| Supabase URL | `https://kakhzbcuudkrrktkobjs.supabase.co` |
| Project Ref | `kakhzbcuudkrrktkobjs` |
| Auth Callback | `https://kakhzbcuudkrrktkobjs.supabase.co/auth/v1/callback` |
| Edge Functions | `generate-questions`, `grade-answer`, `challenge-answer` |
| Daily Limits | generate: 50, grade: 300, challenge: 50 |
