//! Server-side mention persistence.
//!
//! When a plaintext message is stored we scan the body for `@<username>`
//! tokens that match a current member of the conversation, plus the
//! broadcast keywords `@everyone` and `@here`.  Each match becomes one
//! row in the `mentions` table keyed by `(message_id, mentioned_user_id)`.
//! The `list_conversations` query joins these rows against the user's
//! `read_receipts` row to compute an unread mention count that survives
//! a page refresh -- the client previously bumped the badge in-memory
//! only, so any reload reset it to zero.
//!
//! Encrypted-group messages skip this entirely: the server never sees
//! plaintext, so the badge for those conversations remains a best-effort
//! client-side signal until per-recipient envelopes carry mention
//! metadata (separate slice).

use sqlx::PgPool;
use uuid::Uuid;

/// Word-boundary check identical in spirit to the client's
/// `containsMention`: the keyword is a standalone token if its left and
/// right neighbours are start/end-of-string or non-word characters
/// (anything other than `[A-Za-z0-9_]`).  Case-insensitive.
pub fn is_standalone_keyword(content: &str, keyword: &str) -> bool {
    if keyword.is_empty() {
        return false;
    }
    if !content.contains('@') {
        return false;
    }
    let target = format!("@{}", keyword.to_lowercase());
    let lower = content.to_lowercase();
    let mut start = 0;
    while let Some(rel) = lower[start..].find(&target) {
        let abs = start + rel;
        let after = abs + target.len();
        let left_ok = abs == 0
            || !lower[..abs]
                .chars()
                .next_back()
                .is_some_and(|c| c.is_alphanumeric() || c == '_');
        let right_ok = after == lower.len()
            || !lower[after..]
                .chars()
                .next()
                .is_some_and(|c| c.is_alphanumeric() || c == '_');
        if left_ok && right_ok {
            return true;
        }
        start = abs + target.len();
    }
    false
}

/// Extract `@<username>` tokens from `content`, normalised lowercase.
/// Returns the de-duplicated set of mentioned usernames.  Pure function;
/// the DB lookup against the conversation's member roster happens in
/// [`extract_and_persist`].
fn extract_at_usernames(content: &str) -> Vec<String> {
    if !content.contains('@') {
        return Vec::new();
    }
    let mut out: Vec<String> = Vec::new();
    let bytes = content.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'@' || !is_left_boundary(content, i) {
            i += 1;
            continue;
        }
        let token_end = scan_word_end(bytes, i + 1);
        if token_end > i + 1 {
            push_unique_non_broadcast(&content[i + 1..token_end], &mut out);
        }
        i = token_end.max(i + 1);
    }
    out
}

/// True when position `i` in `content` is at the start-of-string or
/// preceded by a non-word character. Boundary check for `@mention`
/// detection: prevents matching e.g. `email@host` as a mention.
fn is_left_boundary(content: &str, i: usize) -> bool {
    i == 0
        || !content[..i]
            .chars()
            .next_back()
            .is_some_and(|c| c.is_alphanumeric() || c == '_')
}

/// Returns the byte index of the first non-word byte at or after `start`.
fn scan_word_end(bytes: &[u8], start: usize) -> usize {
    let mut end = start;
    while end < bytes.len() {
        let c = bytes[end];
        if !(c.is_ascii_alphanumeric() || c == b'_') {
            break;
        }
        end += 1;
    }
    end
}

/// Lowercase `token` and push onto `out` unless it is a broadcast keyword
/// (`everyone` / `here`, resolved separately) or already present.
fn push_unique_non_broadcast(token: &str, out: &mut Vec<String>) {
    let lower = token.to_lowercase();
    if lower != "everyone" && lower != "here" && !out.contains(&lower) {
        out.push(lower);
    }
}

/// Resolve broadcast keywords to all non-removed members of the conversation.
async fn resolve_broadcast_members(
    pool: &PgPool,
    conversation_id: Uuid,
) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT cm.user_id FROM conversation_members cm \
         WHERE cm.conversation_id = $1 AND cm.is_removed = false",
    )
    .bind(conversation_id)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(uid,)| uid).collect())
}

/// Resolve explicit `@<username>` tokens to matching members of the conversation.
async fn resolve_username_mentions(
    pool: &PgPool,
    conversation_id: Uuid,
    usernames: &[String],
) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT cm.user_id FROM conversation_members cm \
         JOIN users u ON u.id = cm.user_id \
         WHERE cm.conversation_id = $1 \
           AND cm.is_removed = false \
           AND LOWER(u.username) = ANY($2::text[])",
    )
    .bind(conversation_id)
    .bind(usernames)
    .fetch_all(pool)
    .await?;
    Ok(rows.into_iter().map(|(uid,)| uid).collect())
}

/// Scan `content` for every mention signal: explicit `@<username>` tokens
/// plus the two broadcast keywords.  Returns the lowercase username list
/// and the broadcast flags as a single tuple so the caller can decide
/// whether any further DB work is required.
fn scan_mention_signals(content: &str) -> (Vec<String>, bool, bool) {
    (
        extract_at_usernames(content),
        is_standalone_keyword(content, "everyone"),
        is_standalone_keyword(content, "here"),
    )
}

/// #829: defence-in-depth -- verify the sender is a non-removed member of
/// the conversation before persisting any mention rows. The upstream
/// `send_message` path already enforces membership, but a future caller
/// that forgets to gate could otherwise turn `@everyone` into an
/// unauthenticated broadcast against an arbitrary group.
async fn sender_is_member(
    pool: &PgPool,
    conversation_id: Uuid,
    sender_id: Uuid,
) -> Result<bool, sqlx::Error> {
    let row: (bool,) = sqlx::query_as(
        "SELECT EXISTS ( \
             SELECT 1 FROM conversation_members \
             WHERE conversation_id = $1 \
               AND user_id = $2 \
               AND is_removed = false \
         )",
    )
    .bind(conversation_id)
    .bind(sender_id)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

/// Resolve the parsed signal set to the de-duplicated, sender-stripped
/// list of `user_id`s to write to the `mentions` table.  For broadcast
/// keywords we pull every member; for `@<username>` we pull only matching
/// members.  Self-mentions are dropped so the sender doesn't bump their
/// own badge.
async fn resolve_mention_targets(
    pool: &PgPool,
    conversation_id: Uuid,
    sender_id: Uuid,
    usernames: &[String],
    mentions_everyone: bool,
    mentions_here: bool,
) -> Result<Vec<Uuid>, sqlx::Error> {
    let mut targets: Vec<Uuid> = Vec::new();

    if mentions_everyone || mentions_here {
        targets.extend(resolve_broadcast_members(pool, conversation_id).await?);
    }

    if !usernames.is_empty() {
        targets.extend(resolve_username_mentions(pool, conversation_id, usernames).await?);
    }

    targets.retain(|uid| *uid != sender_id);
    targets.sort_unstable();
    targets.dedup();
    Ok(targets)
}

/// Bulk-insert one row per target into `mentions` with `ON CONFLICT DO
/// Look up the user ids @-mentioned in a single message. Used by the
/// thread-push dampening path (M4): a reply notifies non-subscribers
/// only when they're explicitly named.
pub async fn get_mentioned_user_ids(
    pool: &PgPool,
    message_id: Uuid,
) -> Result<Vec<Uuid>, sqlx::Error> {
    let rows: Vec<(Uuid,)> =
        sqlx::query_as("SELECT mentioned_user_id FROM mentions WHERE message_id = $1")
            .bind(message_id)
            .fetch_all(pool)
            .await?;
    Ok(rows.into_iter().map(|(id,)| id).collect())
}

/// NOTHING` so a redelivery is a no-op.  Uses `UNNEST` to bind a single
/// array parameter rather than building a variadic `VALUES` clause.
async fn insert_mention_rows(
    pool: &PgPool,
    message_id: Uuid,
    targets: &[Uuid],
) -> Result<usize, sqlx::Error> {
    let inserted = sqlx::query(
        "INSERT INTO mentions (message_id, mentioned_user_id) \
         SELECT $1, uid FROM UNNEST($2::uuid[]) AS t(uid) \
         ON CONFLICT DO NOTHING",
    )
    .bind(message_id)
    .bind(targets)
    .execute(pool)
    .await?;
    Ok(inserted.rows_affected() as usize)
}

/// Insert mention rows for `message_id` in conversation `conv_id`.
///
/// Resolves `@<username>` tokens against the conversation's member list
/// (excluding the sender, who can't mention themselves) and includes
/// every member when `@everyone` or `@here` appears.  Idempotent: rows
/// conflict on the composite primary key and the second insert is a no-op.
///
/// Returns the number of rows inserted on this call.  Errors are
/// propagated; callers typically log and continue so a mention-table
/// failure never blocks the actual message send.
pub async fn extract_and_persist(
    pool: &PgPool,
    message_id: Uuid,
    conversation_id: Uuid,
    sender_id: Uuid,
    content: &str,
) -> Result<usize, sqlx::Error> {
    let (usernames, mentions_everyone, mentions_here) = scan_mention_signals(content);

    if usernames.is_empty() && !mentions_everyone && !mentions_here {
        return Ok(0);
    }

    // Bail with an empty result so callers' logging stays quiet on
    // legitimate misses (non-member sender, e.g. removed mid-flight).
    if !sender_is_member(pool, conversation_id, sender_id).await? {
        return Ok(0);
    }

    let targets = resolve_mention_targets(
        pool,
        conversation_id,
        sender_id,
        &usernames,
        mentions_everyone,
        mentions_here,
    )
    .await?;

    if targets.is_empty() {
        return Ok(0);
    }

    insert_mention_rows(pool, message_id, &targets).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_simple_username() {
        assert_eq!(extract_at_usernames("hi @alice"), vec!["alice"]);
    }

    #[test]
    fn case_insensitive() {
        assert_eq!(
            extract_at_usernames("@Alice and @BOB"),
            vec!["alice", "bob"]
        );
    }

    #[test]
    fn skips_broadcast_keywords() {
        assert!(extract_at_usernames("@everyone @here").is_empty());
    }

    #[test]
    fn requires_word_boundary_left() {
        // Email-like patterns must not be parsed as mentions.
        assert!(extract_at_usernames("ping me at me@host").is_empty());
    }

    #[test]
    fn empty_for_no_at() {
        assert!(extract_at_usernames("hello world").is_empty());
    }

    #[test]
    fn dedupes_repeated_mentions() {
        assert_eq!(extract_at_usernames("@alice @alice @alice"), vec!["alice"]);
    }

    #[test]
    fn detects_broadcast_keyword() {
        assert!(is_standalone_keyword("@everyone get in", "everyone"));
        assert!(is_standalone_keyword("ping @here", "here"));
        assert!(!is_standalone_keyword("@hereafter", "here"));
    }

    #[test]
    fn standalone_keyword_with_punctuation() {
        assert!(is_standalone_keyword("@here, please", "here"));
        assert!(is_standalone_keyword("psst.@here!", "here"));
    }

    #[test]
    fn standalone_keyword_rejects_email_prefix() {
        assert!(!is_standalone_keyword("x@here", "here"));
    }

    #[test]
    fn standalone_keyword_rejects_underscore_suffix() {
        assert!(!is_standalone_keyword("@here_lounge", "here"));
    }

    #[test]
    fn standalone_keyword_is_case_insensitive() {
        assert!(is_standalone_keyword("Yo @Here folks", "here"));
        assert!(is_standalone_keyword("YO @HERE FOLKS", "here"));
    }

    #[test]
    fn standalone_keyword_no_at_is_false() {
        assert!(!is_standalone_keyword("normal message", "here"));
        assert!(!is_standalone_keyword("", "here"));
    }
}
