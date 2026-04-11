//! WebSocket connection hub for routing messages to online users.
//!
//! Supports multiple simultaneous connections per user (multi-device).
//! Each connection is keyed by `(user_id, device_id)`.

use axum::extract::ws::Message as WsMessage;
use dashmap::DashMap;
use tokio::sync::mpsc;
use uuid::Uuid;

pub type WsTx = mpsc::Sender<WsMessage>;

#[derive(Debug, Default, Clone)]
pub struct Hub {
    /// user_id -> (device_id -> sender channel)
    connections: DashMap<Uuid, DashMap<i32, WsTx>>,
}

impl Hub {
    pub fn new() -> Self {
        Self {
            connections: DashMap::new(),
        }
    }

    /// Register a device connection. Multiple devices per user are supported.
    pub fn register(&self, user_id: Uuid, device_id: i32, tx: WsTx) {
        self.connections
            .entry(user_id)
            .or_default()
            .insert(device_id, tx);
    }

    /// Unregister a specific device. Cleans up the user entry if no devices remain.
    pub fn unregister(&self, user_id: Uuid, device_id: i32) {
        if let Some(devices) = self.connections.get(&user_id) {
            devices.remove(&device_id);
            if devices.is_empty() {
                drop(devices);
                // Re-check after dropping the ref to avoid race
                self.connections
                    .remove_if(&user_id, |_, devs| devs.is_empty());
            }
        }
    }

    /// Unregister ALL devices for a user (e.g., account deletion).
    pub fn unregister_all(&self, user_id: Uuid) {
        self.connections.remove(&user_id);
    }

    pub fn get_online_user_ids(&self) -> Vec<Uuid> {
        self.connections.iter().map(|entry| *entry.key()).collect()
    }

    /// Send a message to ALL connected devices of a user.
    pub fn send_to_user(&self, user_id: &Uuid, msg: WsMessage) -> bool {
        if let Some(devices) = self.connections.get(user_id) {
            let mut any_sent = false;
            for entry in devices.iter() {
                if entry.value().try_send(msg.clone()).is_ok() {
                    any_sent = true;
                }
            }
            any_sent
        } else {
            false
        }
    }

    /// Send a message to a specific device of a user.
    pub fn send_to_device(&self, user_id: &Uuid, device_id: i32, msg: WsMessage) -> bool {
        if let Some(devices) = self.connections.get(user_id)
            && let Some(tx) = devices.get(&device_id)
        {
            return tx.try_send(msg).is_ok();
        }
        false
    }

    /// Backward-compatible: send to user (all devices). Alias for `send_to_user`.
    pub fn send_to(&self, user_id: &Uuid, msg: WsMessage) -> bool {
        self.send_to_user(user_id, msg)
    }

    /// Broadcast a JSON event to all members of a conversation, optionally excluding one user.
    pub fn broadcast_json(&self, member_ids: &[Uuid], json: &str, exclude: Option<Uuid>) {
        for member_id in member_ids {
            if Some(*member_id) == exclude {
                continue;
            }
            self.send_to_user(member_id, WsMessage::Text(json.to_string().into()));
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
        let (tx, mut rx) = mpsc::channel(16);

        hub.register(user_id, 1, tx);
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
        let (tx, _rx) = mpsc::channel(16);

        hub.register(user_id, 1, tx);
        hub.unregister(user_id, 1);

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

    #[tokio::test]
    async fn test_multi_device_delivery() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx1, mut rx1) = mpsc::channel(16);
        let (tx2, mut rx2) = mpsc::channel(16);

        hub.register(user_id, 1, tx1);
        hub.register(user_id, 2, tx2);

        let sent = hub.send_to_user(&user_id, WsMessage::Text("hello".into()));
        assert!(sent);

        let msg1 = rx1.recv().await.unwrap();
        let msg2 = rx2.recv().await.unwrap();
        match (msg1, msg2) {
            (WsMessage::Text(t1), WsMessage::Text(t2)) => {
                assert_eq!(t1.as_str(), "hello");
                assert_eq!(t2.as_str(), "hello");
            }
            _ => panic!("Expected Text messages"),
        }
    }

    #[tokio::test]
    async fn test_send_to_specific_device() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx1, mut rx1) = mpsc::channel(16);
        let (tx2, mut rx2) = mpsc::channel(16);

        hub.register(user_id, 1, tx1);
        hub.register(user_id, 2, tx2);

        let sent = hub.send_to_device(&user_id, 2, WsMessage::Text("device2".into()));
        assert!(sent);

        // Device 2 should receive it
        let msg = rx2.recv().await.unwrap();
        match msg {
            WsMessage::Text(t) => assert_eq!(t.as_str(), "device2"),
            _ => panic!("Expected Text message"),
        }

        // Device 1 should NOT have a message
        assert!(rx1.try_recv().is_err());
    }

    #[tokio::test]
    async fn test_unregister_one_device_keeps_others() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx1, _rx1) = mpsc::channel(16);
        let (tx2, mut rx2) = mpsc::channel(16);

        hub.register(user_id, 1, tx1);
        hub.register(user_id, 2, tx2);
        hub.unregister(user_id, 1);

        let sent = hub.send_to_user(&user_id, WsMessage::Text("still here".into()));
        assert!(sent);

        match rx2.recv().await.unwrap() {
            WsMessage::Text(t) => assert_eq!(t.as_str(), "still here"),
            _ => panic!("Expected Text"),
        }
    }
}
