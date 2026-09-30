/** Pure support-search and recovery-email rules. No network. */

export const APP_AUTH_REDIRECT = "roadtriptrivia://auth/callback";

export interface SupportAccount {
  id: string;
  username: string | null;
  usernameNormalized: string | null;
  profileEmail: string | null;
  authEmail: string | null;
  displayName: string | null;
  metadataName: string | null;
  createdAt: string | null;
}

export type RecoveryKind = "recovery" | "magic_link";

export interface PlannedRecoveryEmail {
  kind: RecoveryKind;
  to: string;
}

export function accountEmail(account: SupportAccount): string {
  return (account.profileEmail || account.authEmail || "").trim();
}

/** Strip LIKE wildcards. A query that is only wildcards matches nobody. */
export function searchNeedle(query: string): string {
  return query.trim().toLowerCase().replace(/[\\%_]/g, "");
}

export function searchSupportAccounts(query: string, accounts: SupportAccount[]): SupportAccount[] {
  const q = query.trim().toLowerCase();
  const needle = searchNeedle(query);
  if (!q || !needle) return [];

  const ranked: Array<{ account: SupportAccount; rank: number }> = [];
  for (const account of accounts) {
    const email = accountEmail(account).toLowerCase();
    const usernameNorm = (account.usernameNormalized ?? "").toLowerCase();
    const username = (account.username ?? "").toLowerCase();
    const display = (account.displayName ?? "").toLowerCase();
    const meta = (account.metadataName ?? "").toLowerCase();
    let rank: number | null = null;
    if (account.id.toLowerCase() === q) rank = 0;
    else if (usernameNorm && usernameNorm === q) rank = 1;
    else if (email && email === q) rank = 2;
    else if (email.includes(needle)) rank = 3;
    else if (
      username.includes(needle) ||
      usernameNorm.includes(needle) ||
      display.includes(needle) ||
      meta.includes(needle)
    ) rank = 4;
    if (rank !== null) ranked.push({ account, rank });
  }

  ranked.sort((a, b) => {
    if (a.rank !== b.rank) return a.rank - b.rank;
    return (b.account.createdAt ?? "").localeCompare(a.account.createdAt ?? "");
  });
  return ranked.slice(0, 8).map((row) => row.account);
}

/** Sign-in and password reset may use only an exact id, username, or email. */
export function exactSupportAccount(query: string, accounts: SupportAccount[]): SupportAccount | null {
  const q = query.trim().toLowerCase();
  if (!q) return null;
  return searchSupportAccounts(query, accounts).find((account) => {
    const email = accountEmail(account).toLowerCase();
    return account.id.toLowerCase() === q ||
      (account.usernameNormalized ?? "").toLowerCase() === q ||
      email === q;
  }) ?? null;
}

export function classifyLookup(count: number): "empty" | "one" | "many" {
  if (count <= 0) return "empty";
  if (count === 1) return "one";
  return "many";
}

export function planRecoveryEmails(
  action: "forgot_password" | "forgot_username" | "magic_link",
  identifier: string,
  account: SupportAccount | null,
): PlannedRecoveryEmail[] {
  const raw = identifier.trim();
  if (action === "forgot_password") {
    const to = account ? accountEmail(account) : (raw.includes("@") ? raw : "");
    return to ? [{ kind: "recovery", to }] : [];
  }
  if (action === "forgot_username") {
    const to = account ? accountEmail(account) : "";
    return raw.includes("@") && to ? [{ kind: "magic_link", to }] : [];
  }
  if (!raw.includes("@")) return [];
  const to = account ? accountEmail(account) || raw : raw;
  return [{ kind: "magic_link", to }];
}

export function authEmailPayload(email: string): { email: string; create_user: false; redirect_to: string } {
  return { email, create_user: false, redirect_to: APP_AUTH_REDIRECT };
}

export function parseMailerError(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return "Email was not sent";
  try {
    const json = JSON.parse(trimmed) as {
      msg?: string;
      message?: string;
      error_description?: string;
      error?: string;
    };
    return json.msg || json.error_description || json.message || json.error || "Email was not sent";
  } catch {
    return trimmed.slice(0, 180);
  }
}

export function roundsPerPeriod(productId: string | null | undefined): number {
  if (productId === "com.nagrom.roadtrip.weekly") return 5;
  if (productId === "com.nagrom.roadtrip.monthly") return 10;
  return 0;
}

export function subscriptionRoundsLeft(input: {
  subscriptionProductId: string | null;
  subscriptionStatus: string | null;
  subscriptionRoundsUsed: number;
}): number {
  if (input.subscriptionStatus !== "active") return 0;
  const allowance = roundsPerPeriod(input.subscriptionProductId);
  if (allowance <= 0) return 0;
  return Math.max(0, allowance - Math.max(0, input.subscriptionRoundsUsed));
}

/** Matches the iPhone badge. Support credits are already inside purchasedRounds. */
export function playableRounds(input: {
  freeRoundUsed: boolean;
  purchasedRounds: number;
  subscriptionProductId: string | null;
  subscriptionStatus: string | null;
  subscriptionRoundsUsed: number;
}): number {
  return (input.freeRoundUsed ? 0 : 1) + subscriptionRoundsLeft(input) + Math.max(0, input.purchasedRounds);
}

export function mailerFailureMessage(error: string | undefined): string {
  if (/after \d+ seconds|rate limit|only request this/i.test(error ?? "")) {
    return "Wait a minute, then try again. Supabase only sends one account email per minute.";
  }
  return "The email could not be sent. Try again in a minute.";
}
