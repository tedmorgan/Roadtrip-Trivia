import { assertStringIncludes } from "jsr:@std/assert@1";

const configURL = new URL("../../config.toml", import.meta.url);
const liveTokenURL = new URL("../gemini-live-token/index.ts", import.meta.url);
const batchURL = new URL("../gemini-question-batch/index.ts", import.meta.url);
const requireUserURL = new URL("./requireUser.ts", import.meta.url);

Deno.test("game functions verify ES256 tokens inside the handler", async () => {
  const config = await Deno.readTextFile(configURL);
  const live = await Deno.readTextFile(liveTokenURL);
  const batch = await Deno.readTextFile(batchURL);
  const checker = await Deno.readTextFile(requireUserURL);

  for (const name of ["gemini-live-token", "gemini-question-batch"]) {
    const block = config.slice(config.indexOf(`[functions.${name}]`));
    assertStringIncludes(block.slice(0, 80), "verify_jwt = false");
  }
  assertStringIncludes(live, "requireUser");
  assertStringIncludes(batch, "requireUser");
  assertStringIncludes(checker, "/auth/v1/user");
});
