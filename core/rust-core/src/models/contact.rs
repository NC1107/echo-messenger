use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Contact {
    pub user_id: Uuid,
    pub username: String,
    pub display_name: Option<String>,
    pub status: ContactStatus,
    pub added_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum ContactStatus {
    Pending,
    Accepted,
    Blocked,
}
