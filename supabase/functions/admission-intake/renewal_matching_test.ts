import { renewalNameMatchScore } from "./renewal_matching.ts";

Deno.test("full extracted name uniquely beats players sharing the surname", () => {
  // Fictional names on purpose: the previous list had been scrubbed to
  // "Player A/D/E/H", which made these assertions unsatisfiable and left two
  // tests failing in the repo long before anyone read them.
  const candidates = [
    "Shrithik Reddy M",
    "Anaya Reddy",
    "Vihaan Rao",
    "Ishaan Reddy",
  ];
  const scores = candidates.map((name) => renewalNameMatchScore("Shrithik Reddy", name));
  if (scores.join(",") !== "55,0,0,0") {
    throw new Error(`Unexpected shared-surname scores: ${scores.join(",")}`);
  }
});

Deno.test("one OCR typo in a supplied full name remains matchable", () => {
  const score = renewalNameMatchScore("Shrithik Redy", "Shrithik Reddy M");
  if (score !== 55) throw new Error(`Expected OCR-tolerant score, received ${score}`);
});

Deno.test("a first name outranks a later-token match", () => {
  const firstNameScore = renewalNameMatchScore("Shrithik", "Shrithik Reddy M");
  const surnameScore = renewalNameMatchScore("Reddy", "Shrithik Reddy M");
  if (firstNameScore !== 55 || surnameScore !== 52) {
    throw new Error(`Unexpected single-token scores: first=${firstNameScore}, surname=${surnameScore}`);
  }
  // Within the caller's 10-point window, so a roster holding both a "Shrithik"
  // and someone else surnamed Reddy stays ambiguous instead of guessing.
  if (firstNameScore - surnameScore > 10) {
    throw new Error("a later-token match must stay close enough to trigger the ambiguity guard");
  }
});

Deno.test("a given name that is not first still identifies the player", () => {
  // Staff say "Aadil" for "Mohammed Aadil". This returned 0 before, so AgentAlpha
  // reported "no player matched" for every player whose given name is not first.
  const score = renewalNameMatchScore("Aadil", "Mohammed Aadil");
  if (score !== 52) throw new Error(`Expected a later-token match, received ${score}`);
  const unrelated = renewalNameMatchScore("Aadil", "Rishi Karthikeya Varanasi");
  if (unrelated !== 0) throw new Error(`Unrelated name must not match, received ${unrelated}`);
});

Deno.test("identical complete names retain the strongest score", () => {
  const score = renewalNameMatchScore("Shrithik Reddy M", "Shrithik Reddy M");
  if (score !== 60) throw new Error(`Expected exact score, received ${score}`);
});
