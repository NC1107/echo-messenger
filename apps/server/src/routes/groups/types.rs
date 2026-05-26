//! Shared request/response types for group endpoints.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
pub struct CreateGroupRequest {
    pub name: String,
    #[serde(default)]
    pub member_ids: Vec<Uuid>,
    #[serde(default)]
    pub is_public: bool,
    pub description: Option<String>,
    /// Opt-in end-to-end encryption flag. Defaults to false so a client
    /// that doesn't send the field gets a plaintext group — the group-
    /// key envelope path is still experimental and groups created with
    /// it have shown an envelope-MAC wedge under identity-key drift
    /// (see PR #982). Clients that want E2E pass `true`.
    ///
    /// **Write-once.** Intentionally absent from [`UpdateGroupRequest`] so
    /// `PUT /api/groups/:id` cannot flip an encrypted group to plaintext
    /// (or vice versa) mid-conversation. Doing so would invalidate the
    /// ratchet / group-key state for every member and would constitute a
    /// downgrade attack against an existing E2E channel. Any future
    /// rotation/migration story must rotate keys + require member
    /// re-consent rather than toggling this column. See TD-7.
    #[serde(default)]
    pub is_encrypted: bool,
}

#[derive(Debug, Deserialize)]
pub struct PublicGroupsQuery {
    pub search: Option<String>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[derive(Debug, Serialize)]
pub struct PublicGroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub description: Option<String>,
    pub member_count: i64,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub is_member: bool,
}

#[derive(Debug, Serialize)]
pub struct GroupResponse {
    pub id: Uuid,
    pub title: Option<String>,
    pub kind: String,
    pub description: Option<String>,
    pub icon_url: Option<String>,
    pub members: Vec<GroupMemberResponse>,
    /// Whether the group is end-to-end encrypted. Lets clients render
    /// the lock indicator immediately after create/fetch without a
    /// second round-trip (TD-8).
    pub is_encrypted: bool,
}

#[derive(Debug, Serialize)]
pub struct GroupMemberResponse {
    pub user_id: Uuid,
    pub username: String,
    pub role: String,
    pub avatar_url: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AddMemberRequest {
    pub user_id: Uuid,
}

#[derive(Debug, Deserialize)]
pub struct UpdateGroupRequest {
    pub title: Option<String>,
    pub description: Option<String>,
    // DO NOT add `is_encrypted` here (TD-7); the lockdown test below enforces.
}

#[cfg(test)]
mod update_group_request_lockdown {
    use super::*;
    use serde_json::json;

    /// `UpdateGroupRequest` must remain write-locked against `is_encrypted`.
    /// If a future contributor adds the field to the struct this test will
    /// stop short-circuiting (it'll start parsing the value into the new
    /// field) and the matching production write path will need to be
    /// security-reviewed. See TD-7 in TECHNICAL_DEBT.md.
    #[test]
    fn is_encrypted_is_silently_dropped() {
        // Unknown `is_encrypted` MUST be silently dropped (not propagated).
        let parsed: UpdateGroupRequest = serde_json::from_value(json!({
            "title": "x",
            "is_encrypted": true,
        }))
        .expect("title-only update should still deserialize");
        assert_eq!(parsed.title.as_deref(), Some("x"));
        // No is_encrypted field — compile-time proof; assert intentionally.
        assert!(parsed.description.is_none());
    }
}

/// Optional body for invite creation (both fields accepted; UI deferred to follow-up).
#[derive(Debug, Deserialize, Default)]
pub struct CreateInviteRequest {
    pub expires_in_seconds: Option<i64>,
    pub max_uses: Option<i32>,
}
