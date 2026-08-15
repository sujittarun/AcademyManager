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
 *     OCR typo in longer tokens, or a single token matching the player's first.
 * 52: a single supplied token matches a LATER token of the player's name.
 *     Staff say "Aadil" for "Mohammed Aadil", and refusing that outright meant
 *     AgentAlpha could never match anyone whose given name is not first. Scored
 *     below a first-token match on purpose: when both exist the caller sees two
 *     candidates within its 10-point window and asks for a registration number
 *     or parent phone instead of guessing. A shared surname behaves the same
 *     way — every holder scores 52, so it stays ambiguous rather than matching
 *     one of them. Nothing is written until staff confirm the review.
 * 0: insufficient identity evidence.
 */
export function renewalNameMatchScore(requested: unknown, candidate: unknown): number {
  const requestedTokens = nameTokens(requested);
  const candidateTokens = nameTokens(candidate);
  if (!requestedTokens.length || !candidateTokens.length) return 0;

  if (requestedTokens.join("") === candidateTokens.join("")) return 60;

  if (requestedTokens.length === 1) {
    if (tokensMatch(requestedTokens[0], candidateTokens[0])) return 55;
    const matchesLaterToken = candidateTokens.slice(1).some((candidateToken) =>
      tokensMatch(requestedTokens[0], candidateToken)
    );
    return matchesLaterToken ? 52 : 0;
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
