//! Database queries for the polls-in-chat feature.
//!
//! Schema: `message_polls(message_id PK, question, options JSONB)` +
//! `poll_votes(message_id, user_id, option_index, PRIMARY KEY(message_id, user_id))`.

use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

/// A row from `message_polls`.
#[derive(Debug, sqlx::FromRow)]
pub struct PollRow {
    pub message_id: Uuid,
    pub question: String,
    pub options: sqlx::types::Json<Vec<String>>,
}

/// One option entry returned by [`get_poll`].
#[derive(Debug, Serialize, Deserialize)]
pub struct PollOptionResult {
    pub text: String,
    pub count: i64,
    pub voters: Vec<Uuid>,
}

/// Full poll result returned by the GET endpoint.
#[derive(Debug, Serialize)]
pub struct PollResult {
    pub question: String,
    pub options: Vec<PollOptionResult>,
    /// UUID of the option the caller voted for, if any.
    pub my_vote: Option<i64>,
}

/// Insert a new poll.  Fails if a poll already exists for `message_id`.
pub async fn create_poll(
    pool: &PgPool,
    message_id: Uuid,
    question: &str,
    options: &[String],
) -> Result<(), sqlx::Error> {
    let options_json =
        serde_json::to_value(options).map_err(|e| sqlx::Error::Decode(Box::new(e)))?;
    sqlx::query(
        "INSERT INTO message_polls (message_id, question, options) \
         VALUES ($1, $2, $3)",
    )
    .bind(message_id)
    .bind(question)
    .bind(options_json)
    .execute(pool)
    .await?;
    Ok(())
}

/// Record (or replace) a vote.  Upserts so the caller can change their vote.
pub async fn upsert_vote(
    pool: &PgPool,
    message_id: Uuid,
    user_id: Uuid,
    option_index: i32,
) -> Result<(), sqlx::Error> {
    sqlx::query(
        "INSERT INTO poll_votes (message_id, user_id, option_index) \
         VALUES ($1, $2, $3) \
         ON CONFLICT (message_id, user_id) DO UPDATE SET option_index = $3, voted_at = NOW()",
    )
    .bind(message_id)
    .bind(user_id)
    .bind(option_index)
    .execute(pool)
    .await?;
    Ok(())
}

/// Fetch the poll for `message_id`, aggregating vote counts per option.
///
/// Returns `None` when no poll exists for the message.
pub async fn get_poll(
    pool: &PgPool,
    message_id: Uuid,
    caller_id: Uuid,
) -> Result<Option<PollResult>, sqlx::Error> {
    // Load the poll definition.
    let row: Option<PollRow> = sqlx::query_as(
        "SELECT message_id, question, options FROM message_polls WHERE message_id = $1",
    )
    .bind(message_id)
    .fetch_optional(pool)
    .await?;

    let poll = match row {
        None => return Ok(None),
        Some(r) => r,
    };

    // Load all votes for this poll.
    #[derive(sqlx::FromRow)]
    struct VoteRow {
        user_id: Uuid,
        option_index: i32,
    }

    let votes: Vec<VoteRow> =
        sqlx::query_as("SELECT user_id, option_index FROM poll_votes WHERE message_id = $1")
            .bind(message_id)
            .fetch_all(pool)
            .await?;

    let option_texts = poll.options.0;
    let n = option_texts.len();

    // Aggregate per option.
    let mut counts: Vec<i64> = vec![0; n];
    let mut voter_lists: Vec<Vec<Uuid>> = vec![vec![]; n];
    let mut my_vote: Option<i64> = None;

    for v in votes {
        let idx = v.option_index as usize;
        if idx < n {
            counts[idx] += 1;
            voter_lists[idx].push(v.user_id);
        }
        if v.user_id == caller_id {
            my_vote = Some(v.option_index as i64);
        }
    }

    let options = option_texts
        .into_iter()
        .enumerate()
        .map(|(i, text)| PollOptionResult {
            text,
            count: counts[i],
            voters: voter_lists[i].clone(),
        })
        .collect();

    Ok(Some(PollResult {
        question: poll.question,
        options,
        my_vote,
    }))
}

/// Return `true` when a poll exists for `message_id`.
pub async fn poll_exists(pool: &PgPool, message_id: Uuid) -> Result<bool, sqlx::Error> {
    let row: Option<(Uuid,)> =
        sqlx::query_as("SELECT message_id FROM message_polls WHERE message_id = $1")
            .bind(message_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.is_some())
}

/// Return the number of options in a poll (for bounds-checking votes).
pub async fn option_count(pool: &PgPool, message_id: Uuid) -> Result<Option<usize>, sqlx::Error> {
    let row: Option<(sqlx::types::Json<Vec<String>>,)> =
        sqlx::query_as("SELECT options FROM message_polls WHERE message_id = $1")
            .bind(message_id)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(j,)| j.0.len()))
}
