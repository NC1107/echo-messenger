//! WebSocket connection hub for routing messages to online users.

use axum::extract::ws::Message as WsMessage;
use dashmap::DashMap;
use tokio::sync::mpsc;
use uuid::Uuid;

pub type WsTx = mpsc::UnboundedSender<WsMessage>;

#[derive(Debug, Default, Clone)]
pub struct Hub {
    connections: DashMap<Uuid, WsTx>,
}

impl Hub {
    pub fn new() -> Self {
        Self {
            connections: DashMap::new(),
        }
    }

    pub fn register(&self, user_id: Uuid, tx: WsTx) {
        self.connections.insert(user_id, tx);
    }

    pub fn unregister(&self, user_id: Uuid) {
        self.connections.remove(&user_id);
    }

    pub fn get_online_user_ids(&self) -> Vec<Uuid> {
        self.connections.iter().map(|entry| *entry.key()).collect()
    }

    pub fn send_to(&self, user_id: &Uuid, msg: WsMessage) -> bool {
        if let Some(tx) = self.connections.get(user_id) {
            tx.send(msg).is_ok()
        } else {
            false
        }
    }

    /// Broadcast a JSON event to all members of a conversation, optionally excluding one user.
    pub fn broadcast_json(&self, member_ids: &[Uuid], json: &str, exclude: Option<Uuid>) {
        for member_id in member_ids {
            if Some(*member_id) == exclude {
                continue;
            }
            self.send_to(member_id, WsMessage::Text(json.to_string().into()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_register_and_send() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, mut rx) = mpsc::unbounded_channel();

        hub.register(user_id, tx);
        let sent = hub.send_to(&user_id, WsMessage::Text("hello".into()));
        assert!(sent);

        let received = rx.recv().await.unwrap();
        match received {
            WsMessage::Text(text) => assert_eq!(text.as_str(), "hello"),
            other => panic!("Expected Text message, got {:?}", other),
        }
    }

    #[tokio::test]
    async fn test_unregister_removes() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, _rx) = mpsc::unbounded_channel();

        hub.register(user_id, tx);
        hub.unregister(user_id);

        let sent = hub.send_to(&user_id, WsMessage::Text("hello".into()));
        assert!(!sent);
    }

    #[test]
    fn test_send_to_offline_returns_false() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();

        let sent = hub.send_to(&user_id, WsMessage::Text("hello".into()));
        assert!(!sent);
    }
}
