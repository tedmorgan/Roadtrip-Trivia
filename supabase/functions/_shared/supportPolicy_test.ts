import { assertEquals } from "jsr:@std/assert@1";
import {
  APP_AUTH_REDIRECT,
  playableRounds,
  authEmailPayload,
  classifyLookup,
  exactSupportAccount,
  mailerFailureMessage,
  parseMailerError,
  planRecoveryEmails,
  searchSupportAccounts,
  type SupportAccount,
} from "./supportPolicy.ts";

const ted: SupportAccount = {
  id: "b97bd73c-2c11-4eec-bfde-4413931df8a3",
  username: null,
  usernameNormalized: null,
  profileEmail: null,
  authEmail: "tedmorgan@gmail.com",
  displayName: "Ted Morgan",
  metadataName: "Ted Morgan",
  createdAt: "2026-03-16T21:00:20Z",
};

const mshean: SupportAccount = {
  id: "de859f45-59b9-4dc7-b825-c69d6f8cd4e8",
  username: null,
  usernameNormalized: null,
  profileEmail: null,
  authEmail: "mshean13@gmail.com",
  displayName: "Player",
  metadataName: null,
  createdAt: "2026-03-11T15:54:36Z",
};

const named: SupportAccount = {
  id: "11111111-1111-1111-1111-111111111111",
  username: "RoadWarrior",
  usernameNormalized: "roadwarrior",
  profileEmail: "road@example.com",
  authEmail: "road@example.com",
  displayName: "Road Warrior",
  metadataName: null,
  createdAt: "2026-01-01T00:00:00Z",
};

const accounts = [ted, mshean, named];

Deno.test("playable rounds match the phone badge", () => {
  assertEquals(playableRounds({
    freeRoundUsed: true,
    purchasedRounds: 1,
    subscriptionProductId: "com.nagrom.roadtrip.monthly",
    subscriptionStatus: "active",
    subscriptionRoundsUsed: 6,
  }), 5);
  assertEquals(playableRounds({
    freeRoundUsed: false,
    purchasedRounds: 0,
    subscriptionProductId: null,
    subscriptionStatus: "none",
    subscriptionRoundsUsed: 0,
  }), 1);
});

Deno.test("full email matches when only the Auth email is stored", () => {
  const found = searchSupportAccounts("tedmorgan@gmail.com", accounts);
  assertEquals(found.map((row) => row.id), [ted.id]);
  assertEquals(exactSupportAccount("TEDMORGAN@gmail.com", accounts)?.id, ted.id);
});

Deno.test("partial email matches the Auth address and is not an exact sign-in", () => {
  const found = searchSupportAccounts("mshean", accounts);
  assertEquals(found.map((row) => row.id), [mshean.id]);
  assertEquals(exactSupportAccount("mshean", accounts), null);
});

Deno.test("display name and exact username match", () => {
  assertEquals(searchSupportAccounts("ted morgan", accounts).map((row) => row.id), [ted.id]);
  assertEquals(exactSupportAccount("RoadWarrior", accounts)?.id, named.id);
  assertEquals(searchSupportAccounts(named.id.toUpperCase(), accounts).map((row) => row.id), [named.id]);
});

Deno.test("a shared fragment returns every match and does not pick one", () => {
  const found = searchSupportAccounts("gmail.com", [ted, mshean]);
  assertEquals(found.length, 2);
  assertEquals(classifyLookup(found.length), "many");
  assertEquals(exactSupportAccount("gmail.com", [ted, mshean]), null);
});

Deno.test("wildcard-only queries match nobody", () => {
  assertEquals(searchSupportAccounts("%", accounts), []);
  assertEquals(searchSupportAccounts("_", accounts), []);
  assertEquals(searchSupportAccounts("   ", accounts), []);
});

Deno.test("search keeps the closest eight matches", () => {
  const many = Array.from({ length: 10 }, (_, index): SupportAccount => ({
    id: `00000000-0000-0000-0000-00000000000${index}`,
    username: null,
    usernameNormalized: null,
    profileEmail: `player${index}@example.com`,
    authEmail: null,
    displayName: "Player",
    metadataName: null,
    createdAt: `2026-01-${String(index + 1).padStart(2, "0")}T00:00:00Z`,
  }));
  const found = searchSupportAccounts("player", many);
  assertEquals(found.length, 8);
  assertEquals(found[0].profileEmail, "player9@example.com");
});

Deno.test("username reminder sends one account email and never a password reset", () => {
  const planned = planRecoveryEmails("forgot_username", "tedmorgan@gmail.com", ted);
  assertEquals(planned, [{ kind: "magic_link", to: "tedmorgan@gmail.com" }]);
  assertEquals(planned.some((email) => email.kind === "recovery"), false);
});

Deno.test("password reset sends one recovery email to the Auth address", () => {
  assertEquals(
    planRecoveryEmails("forgot_password", "tedmorgan@gmail.com", ted),
    [{ kind: "recovery", to: "tedmorgan@gmail.com" }],
  );
  assertEquals(
    planRecoveryEmails("forgot_password", "roadwarrior", named),
    [{ kind: "recovery", to: "road@example.com" }],
  );
  assertEquals(planRecoveryEmails("forgot_password", "nobody", null), []);
});

Deno.test("magic link falls back to the typed email when no profile exists", () => {
  assertEquals(
    planRecoveryEmails("magic_link", "new@example.com", null),
    [{ kind: "magic_link", to: "new@example.com" }],
  );
});

Deno.test("auth emails redirect into the app", () => {
  assertEquals(authEmailPayload("tedmorgan@gmail.com"), {
    email: "tedmorgan@gmail.com",
    create_user: false,
    redirect_to: APP_AUTH_REDIRECT,
  });
  assertEquals(APP_AUTH_REDIRECT, "roadtriptrivia://auth/callback");
});

Deno.test("a rate-limited mailer is reported instead of treated as sent", () => {
  const parsed = parseMailerError(
    JSON.stringify({ msg: "For security purposes, you can only request this after 60 seconds." }),
  );
  assertEquals(
    mailerFailureMessage(parsed),
    "Wait a minute, then try again. Supabase only sends one account email per minute.",
  );
  assertEquals(
    mailerFailureMessage(parseMailerError('{"error":"redirect_to is not allowed"}')),
    "The email could not be sent. Try again in a minute.",
  );
  assertEquals(parseMailerError("mailbox unavailable"), "mailbox unavailable");
});

Deno.test("shipped email templates name the account and open the app", async () => {
  const root = new URL("../../", import.meta.url);
  const magic = await Deno.readTextFile(new URL("templates/magic-link.html", root));
  const recovery = await Deno.readTextFile(new URL("templates/recovery.html", root));
  const config = await Deno.readTextFile(new URL("config.toml", root));
  const sql = await Deno.readTextFile(new URL("migrations/20260925_support_account_search.sql", root));

  assertEquals(magic.includes("{{ .Email }}"), true);
  assertEquals(magic.includes("{{ .Data.username }}"), true);
  assertEquals(magic.includes("{{ .ConfirmationURL }}"), true);
  assertEquals(magic.toLowerCase().includes("magic link"), false);
  assertEquals(magic.includes("localhost"), false);

  assertEquals(recovery.includes("new password"), true);
  assertEquals(recovery.includes("{{ .ConfirmationURL }}"), true);
  assertEquals(recovery.includes("localhost"), false);

  assertEquals(config.includes('site_url = "roadtriptrivia://auth/callback"'), true);
  assertEquals(config.includes('subject = "Your Roadtrip Trivia account"'), true);
  assertEquals(config.includes('subject = "Reset your Roadtrip Trivia password"'), true);

  assertEquals(sql.includes("u.email"), true);
  assertEquals(sql.includes("display_name"), true);
  assertEquals(sql.includes("raw_user_meta_data"), true);
  assertEquals(sql.includes("like q_like"), true);
});
