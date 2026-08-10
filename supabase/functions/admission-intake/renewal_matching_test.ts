import { renewalNameMatchScore } from "./renewal_matching.ts";

Deno.test("full extracted name uniquely beats players sharing the surname", () => {
  const candidates = [
    "Player D",
    "Player A",
    "Player H",
    "Player E",
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

Deno.test("a first name alone can identify a player but a shared surname cannot", () => {
  const firstNameScore = renewalNameMatchScore("Shrithik", "Shrithik Reddy M");
  const surnameScore = renewalNameMatchScore("Reddy", "Shrithik Reddy M");
  if (firstNameScore !== 55 || surnameScore !== 0) {
    throw new Error(`Unexpected single-token scores: first=${firstNameScore}, surname=${surnameScore}`);
  }
});

Deno.test("identical complete names retain the strongest score", () => {
  const score = renewalNameMatchScore("Shrithik Reddy M", "Player D");
  if (score !== 60) throw new Error(`Expected exact score, received ${score}`);
});
