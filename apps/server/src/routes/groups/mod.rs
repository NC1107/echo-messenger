//! Group management REST endpoints, split into focused submodules.
//!
//! | Module       | Responsibility                                        |
//! |--------------|-------------------------------------------------------|
//! | `types`      | Shared request / response structs                     |
//! | `create`     | Group creation and retrieval (`POST /`, `GET /:id`)   |
//! | `members`    | Add / remove / ban / unban members                    |
//! | `lifecycle`  | Leave and delete a group                              |
//! | `public`     | Public group discovery and direct join                |
//! | `settings`   | Update metadata and manage the group avatar           |
//! | `invite`     | Invite-link create / list / preview / accept / revoke |

mod create;
mod invite;
mod lifecycle;
pub(super) mod members;
mod public;
mod settings;
mod types;

// ---------------------------------------------------------------------------
// Re-exports consumed by routes/mod.rs
// ---------------------------------------------------------------------------

pub use create::{create_group, get_group};

pub use members::{add_member, ban_member, change_member_role, remove_member, unban_member};

pub use lifecycle::{delete_group, leave_group};

pub use public::{featured_group, get_group_preview, join_group, list_public_groups};

pub use settings::MAX_GROUP_AVATAR_SIZE;
pub use settings::{get_group_avatar, update_group, upload_group_avatar};

pub use invite::{accept_invite, create_invite, get_invite_preview, list_invites, revoke_invite};
