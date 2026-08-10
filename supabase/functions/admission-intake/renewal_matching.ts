function nameTokens(value: unknown): string[] {
  return String(value || "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean);
}

function editDistance(left: string, right: string): number {
  const previous = Array.from({ length: right.length + 1 }, (_, index) => index);
  for (let i = 1; i <= left.length; i += 1) {
    let diagonal = previous[0];
    previous[0] = i;
    for (let j = 1; j <= right.length; j += 1) {
      const above = previous[j];
      previous[j] = Math.min(
        previous[j] + 1,
        previous[j - 1] + 1,
        diagonal + (left[i - 1] === right[j - 1] ? 0 : 1),
      );
      diagonal = above;
    }
  }
  return previous[right.length];
}

function tokensMatch(left: string, right: string): boolean {
  if (left.length < 3 || right.length < 3) return left === right;
  const allowedDistance = Math.max(left.length, right.length) >= 5 ? 1 : 0;
  return editDistance(left, right) <= allowedDistance;
}

/**
 * Scores a player name without allowing a shared surname to become a match.
 *
 * 60: the complete normalized names are identical.
 * 55: all supplied name tokens match distinct candidate tokens, allowing one
 *     OCR typo in longer tokens. A single supplied token must be the player's
 *     first token (or their complete one-token name).
 * 0: insufficient identity evidence.
 */
export function renewalNameMatchScore(requested: unknown, candidate: unknown): number {
  const requestedTokens = nameTokens(requested);
  const candidateTokens = nameTokens(candidate);
  if (!requestedTokens.length || !candidateTokens.length) return 0;

  if (requestedTokens.join("") === candidateTokens.join("")) return 60;

  if (requestedTokens.length === 1) {
    const isFirstName = tokensMatch(requestedTokens[0], candidateTokens[0]);
    const isCompleteSingleName = candidateTokens.length === 1 &&
      tokensMatch(requestedTokens[0], candidateTokens[0]);
    return isFirstName || isCompleteSingleName ? 55 : 0;
  }

  const unusedCandidateIndexes = new Set(candidateTokens.map((_, index) => index));
  for (const requestedToken of requestedTokens) {
    const matchingIndex = [...unusedCandidateIndexes].find((candidateIndex) =>
      tokensMatch(requestedToken, candidateTokens[candidateIndex])
    );
    if (matchingIndex === undefined) return 0;
    unusedCandidateIndexes.delete(matchingIndex);
  }
  return 55;
}
