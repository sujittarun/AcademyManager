const REVIEW_ACTION = /^(?:confirm(?:ed)?|approve(?:d)?|save(?: it)?|proceed|cancel|discard|reject|yes|yep|yeah|ok(?:ay)?|correct|all correct|looks good|all good|go ahead|do it|sure|done)(?:\s|$)/i;
const CORRECTION_CONTEXT = /\b(?:change|check|correct|correction|instead|actually|should be|update|edit|remove|ignore|mark (?:it )?as|pending|not paid|unpaid|not do(?:ne)?|wrong)\b/i;
const FIELD_UPDATE_CONTEXT = /(?:^|\b)(?:(?:school|college|address|city|name|student name|guardian|father|mother|phone|contact|dob|date of birth|gender|nationality|batch|time slot|joining date|payment date|fee plan|plan|amount)\s+(?:is|are|should be|will be)|(?:mark|set|use|take|put|register)\b)/i;
const NEW_CASE_BOUNDARY = /(?:\b(?:agent\s*alpha|agen\s*alpha|agent\s*alfa)\b.*\b(?:new|start|read|process|admission|renewal)\b|\b(?:new|start)\s+(?:admission|renewal)\b|\bread\s+and\s+process\b|\bprocess\s+this\b)/i;

type ActiveBundleSession = {
  status?: string;
  intake_type?: string;
  last_message_at?: string;
  updated_at?: string;
};

type BundleMessage = {
  message_type?: string;
  text_body?: string;
  reply_to_provider_message_id?: string;
};

type ProcessingGeneration = {
  status?: string;
  updated_at?: string;
};

export function hasExplicitNewCaseBoundary(text: string): boolean {
  return NEW_CASE_BOUNDARY.test(text.trim());
}

/**
 * Meta can deliver the text and media from one staff action as separate HTTP
 * requests. Keep them in one short-lived bundle even when the first request
 * has already moved from collecting to processing/review.
 */
export function shouldContinueActiveBundle(
  session: ActiveBundleSession,
  message: BundleMessage,
  now = Date.now(),
  captureWindowMs = 2 * 60_000,
): boolean {
  if (String(message.reply_to_provider_message_id || "").trim()) return false;
  if (!["text", "image", "document", "audio", "video"].includes(String(message.message_type || ""))) return false;
  if (!["collecting", "processing", "waiting_for_confirmation"].includes(String(session.status || ""))) return false;

  const lastActivity = Date.parse(String(session.last_message_at || session.updated_at || ""));
  if (!Number.isFinite(lastActivity) || now - lastActivity < 0 || now - lastActivity > captureWindowMs) return false;

  const knownCase = session.intake_type === "admission" || session.intake_type === "renewal";
  if (knownCase && hasExplicitNewCaseBoundary(String(message.text_body || ""))) return false;

  // Unthreaded media after a complete review is more safely treated as a new
  // case. Staff can use WhatsApp Reply to attach payment proof to that review.
  if (knownCase && session.status === "waiting_for_confirmation" && message.message_type !== "text") return false;
  return true;
}

export function isSameProcessingGeneration(
  claimed: ProcessingGeneration,
  current: ProcessingGeneration,
): boolean {
  return claimed.status === "processing" && current.status === "processing" &&
    Boolean(claimed.updated_at) && claimed.updated_at === current.updated_at;
}

export function shouldTargetWaitingReview(
  messageType: string,
  text: string,
  replyToProviderMessageId = "",
): boolean {
  if (replyToProviderMessageId.trim()) return true;
  if (messageType !== "text") return false;
  const normalized = text.trim().toLowerCase().replace(/[^a-z0-9 ]+/g, " ").replace(/\s+/g, " ");
  if (!normalized) return false;
  return REVIEW_ACTION.test(normalized) || CORRECTION_CONTEXT.test(normalized) ||
    FIELD_UPDATE_CONTEXT.test(normalized);
}

type WaitingReview = {
  intake_type?: string;
  confirmation_message_id?: string;
  updated_at?: string;
};

type ExpiredReview = WaitingReview & {
  status?: string;
  error_code?: string;
  missing_fields?: unknown[];
  extraction_version?: number;
};

/**
 * Natural, unthreaded replies such as "yes" belong to the latest bot review
 * when that review is clearly newer than every other open review.
 * Otherwise the caller must ask staff to use WhatsApp Reply.
 */
export function selectWaitingReviewCandidate<T extends WaitingReview>(
  rows: T[],
): T | "ambiguous" | null {
  const candidates = rows
    .filter((row) =>
      (row.intake_type === "admission" || row.intake_type === "renewal") &&
      Boolean(row.confirmation_message_id?.trim()) &&
      Number.isFinite(Date.parse(String(row.updated_at || "")))
    )
    .sort((a, b) => Date.parse(String(b.updated_at)) - Date.parse(String(a.updated_at)));

  if (!candidates.length) return null;
  if (candidates.length === 1) return candidates[0];

  const latestAt = Date.parse(String(candidates[0].updated_at));
  const previousAt = Date.parse(String(candidates[1].updated_at));
  const isClearlyLatest = latestAt - previousAt >= 90_000;
  return isClearlyLatest ? candidates[0] : "ambiguous";
}

export function selectRecentExpiredReviewCandidate<T extends ExpiredReview>(
  rows: T[],
  now = Date.now(),
  graceMs = 10 * 60_000,
): T | "ambiguous" | null {
  const recent = rows.filter((row) => {
    const updatedAt = Date.parse(String(row.updated_at || ""));
    return row.status === "expired" && row.error_code === "session_idle_timeout" &&
      Number.isFinite(updatedAt) && now - updatedAt >= 0 && now - updatedAt <= graceMs;
  });
  const viable = recent.filter((row) =>
    (row.intake_type === "admission" || row.intake_type === "renewal") &&
    Boolean(row.confirmation_message_id?.trim())
  );
  if (viable.length > 1) {
    const ranked = [...viable].sort((left, right) => {
      const missingDifference = (left.missing_fields?.length || 0) - (right.missing_fields?.length || 0);
      if (missingDifference !== 0) return missingDifference;
      const versionDifference = Number(right.extraction_version || 0) - Number(left.extraction_version || 0);
      if (versionDifference !== 0) return versionDifference;
      return Date.parse(String(right.updated_at)) - Date.parse(String(left.updated_at));
    });
    const bestMissing = ranked[0].missing_fields?.length || 0;
    const nextMissing = ranked[1].missing_fields?.length || 0;
    if (nextMissing - bestMissing >= 3) return ranked[0];
  }
  return selectWaitingReviewCandidate(recent);
}
