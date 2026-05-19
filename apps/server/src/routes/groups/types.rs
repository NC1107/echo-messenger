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
    /// (see fix in v0.0.379). Clients that want E2E pass `true`.
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
}

/// Optional body for invite creation (both fields accepted; UI deferred to follow-up).
#[derive(Debug, Deserialize, Default)]
pub struct CreateInviteRequest {
    pub expires_in_seconds: Option<i64>,
    pub max_uses: Option<i32>,
}
