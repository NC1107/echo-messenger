//! WebSocket connection hub for routing messages to online users.
//!
//! Supports multiple simultaneous connections per user (multi-device).
//! Each connection is keyed by `(user_id, device_id)`.

use axum::extract::ws::Message as WsMessage;
use dashmap::DashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::sync::mpsc::error::TrySendError;
use uuid::Uuid;

pub type WsTx = mpsc::Sender<WsMessage>;

/// Slow-consumer eviction threshold: this many consecutive `Full` results
/// inside the window unregister the device so the client must reconnect.
const SLOW_CONSUMER_FULL_THRESHOLD: u32 = 50;
const SLOW_CONSUMER_WINDOW: Duration = Duration::from_secs(60);

#[derive(Debug, Default, Clone)]
pub struct Hub {
    inner: std::sync::Arc<HubInner>,
}

#[derive(Debug, Default)]
struct HubInner {
    /// user_id -> (device_id -> sender channel)
    connections: DashMap<Uuid, DashMap<i32, WsTx>>,
    /// Per-(user, device) counter of consecutive `try_send` Full results.
    /// Reset on any successful send.  When the counter exceeds the threshold
    /// inside the rolling window, the device is unregistered.
    full_counters: DashMap<(Uuid, i32), FullCounter>,
}

#[derive(Debug, Default)]
struct FullCounter {
    consecutive: AtomicU32,
    first_failure_at: std::sync::Mutex<Option<Instant>>,
}

impl Hub {
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a device connection. Multiple devices per user are supported.
    pub fn register(&self, user_id: Uuid, device_id: i32, tx: WsTx) {
        self.inner
            .connections
            .entry(user_id)
            .or_default()
            .insert(device_id, tx);
        // Wipe any stale slow-consumer counter from a previous session.
        self.inner.full_counters.remove(&(user_id, device_id));
    }

    /// Unregister a specific device. Cleans up the user entry if no devices remain.
    pub fn unregister(&self, user_id: Uuid, device_id: i32) {
        if let Some(devices) = self.inner.connections.get(&user_id) {
            devices.remove(&device_id);
            if devices.is_empty() {
                drop(devices);
                // Re-check after dropping the ref to avoid race
                self.inner
                    .connections
                    .remove_if(&user_id, |_, devs| devs.is_empty());
            }
        }
        // Drop the slow-consumer counter alongside the connection so a future
        // reconnect from the same device gets a clean slate.
        self.inner.full_counters.remove(&(user_id, device_id));
    }

    /// Unregister ALL devices for a user (e.g., account deletion).
    pub fn unregister_all(&self, user_id: Uuid) {
        self.inner.connections.remove(&user_id);
    }

    pub fn get_online_user_ids(&self) -> Vec<Uuid> {
        self.inner
            .connections
            .iter()
            .map(|entry| *entry.key())
            .collect()
    }

    /// Number of devices currently registered for `user_id`.  Used by the
    /// presence broadcaster (#436) to gate `online`/`offline` events on
    /// first-device-up / last-device-down so a user with three devices
    /// reconnecting after a flaky network blip doesn't make contacts see
    /// online/offline/online/offline per device.
    pub fn device_count(&self, user_id: &Uuid) -> usize {
        self.inner
            .connections
            .get(user_id)
            .map(|devices| devices.len())
            .unwrap_or(0)
    }

    /// Send a message to ALL connected devices of a user.
    /// Returns true if at least one device's outbound queue accepted the
    /// message. Full/closed queues are logged separately so beta-test
    /// telemetry distinguishes saturation from disconnect cleanup.
    pub fn send_to_user(&self, user_id: &Uuid, msg: WsMessage) -> bool {
        // Snapshot the device IDs while holding the read ref so we can
        // mutate `connections` (via `unregister`) without re-entrant locks
        // on the slow-consumer eviction path below.
        let device_ids: Vec<(i32, WsTx)> = {
            let Some(devices) = self.inner.connections.get(user_id) else {
                return false;
            };
            devices
                .iter()
                .map(|e| (*e.key(), e.value().clone()))
                .collect()
        };

        let mut any_sent = false;
        for (device_id, tx) in device_ids {
            if self.try_send_tracked(*user_id, device_id, &tx, msg.clone()) {
                any_sent = true;
            }
        }
        any_sent
    }

    /// Send a message to a specific device of a user. Returns true only when
    /// the message was actually enqueued — callers in the replay path rely
    /// on this to avoid prematurely marking messages as delivered (#523).
    pub fn send_to_device(&self, user_id: &Uuid, device_id: i32, msg: WsMessage) -> bool {
        let tx_opt: Option<WsTx> = self
            .inner
            .connections
            .get(user_id)
            .and_then(|devices| devices.get(&device_id).map(|e| e.value().clone()));
        match tx_opt {
            Some(tx) => self.try_send_tracked(*user_id, device_id, &tx, msg),
            None => false,
        }
    }

    /// Backward-compatible: send to user (all devices). Alias for `send_to_user`.
    pub fn send_to(&self, user_id: &Uuid, msg: WsMessage) -> bool {
        self.send_to_user(user_id, msg)
    }

    /// Broadcast a JSON event to all members of a conversation, optionally excluding one user.
    ///
    /// The JSON string is converted to a `WsMessage` once. Subsequent sends clone the
    /// `WsMessage`, which is O(1) because `axum`'s `Message::Text` is backed by
    /// `bytes::Bytes` (reference-counted). This avoids one `String` allocation per
    /// recipient compared to constructing a new message inside the loop.
    pub fn broadcast_json(&self, member_ids: &[Uuid], json: &str, exclude: Option<Uuid>) {
        let msg = WsMessage::Text(json.into());
        for member_id in member_ids {
            if Some(*member_id) == exclude {
                continue;
            }
            self.send_to_user(member_id, msg.clone());
        }
    }
}

impl Hub {
    /// `try_send` plus slow-consumer tracking. Force-unregisters once the
    /// threshold trips so a stalled tab can't starve itself indefinitely.
    fn try_send_tracked(&self, user_id: Uuid, device_id: i32, tx: &WsTx, msg: WsMessage) -> bool {
        match tx.try_send(msg) {
            Ok(()) => {
                // Reset the counter on any success.
                self.inner.full_counters.remove(&(user_id, device_id));
                true
            }
            Err(TrySendError::Full(_)) => {
                let kick = self.record_full(user_id, device_id);
                tracing::warn!(
                    %user_id,
                    device_id,
                    "WS outbound queue full -- message not delivered"
                );
                if kick {
                    tracing::warn!(
                        %user_id,
                        device_id,
                        threshold = SLOW_CONSUMER_FULL_THRESHOLD,
                        window_secs = SLOW_CONSUMER_WINDOW.as_secs(),
                        "slow consumer threshold reached -- forcing reconnect"
                    );
                    self.unregister(user_id, device_id);
                }
                false
            }
            Err(TrySendError::Closed(_)) => {
                tracing::debug!(
                    %user_id,
                    device_id,
                    "WS outbound queue closed -- recipient disconnected"
                );
                // Closed (rather than Full) indicates the receiver is gone --
                // no point keeping the counter.
                self.inner.full_counters.remove(&(user_id, device_id));
                false
            }
        }
    }

    /// Increment the failure counter for `(user_id, device_id)`.  Returns
    /// `true` when the threshold has just been reached and the caller should
    /// unregister the device.  The window is rolling: if the first failure
    /// is older than `SLOW_CONSUMER_WINDOW`, the counter resets.
    fn record_full(&self, user_id: Uuid, device_id: i32) -> bool {
        let counter = self
            .inner
            .full_counters
            .entry((user_id, device_id))
            .or_default();

        // Rolling-window reset: if the first failure was longer ago than the
        // window, treat this Full as a fresh start.
        let now = Instant::now();
        let mut first_failure_at = counter.first_failure_at.lock().unwrap();
        match *first_failure_at {
            Some(t) if now.duration_since(t) > SLOW_CONSUMER_WINDOW => {
                *first_failure_at = Some(now);
                counter.consecutive.store(1, Ordering::Relaxed);
                false
            }
            None => {
                *first_failure_at = Some(now);
                counter.consecutive.store(1, Ordering::Relaxed);
                false
            }
            Some(_) => {
                let n = counter.consecutive.fetch_add(1, Ordering::Relaxed) + 1;
                n >= SLOW_CONSUMER_FULL_THRESHOLD
            }
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
    async fn test_broadcast_json_delivers_to_all_except_excluded() {
        let hub = Hub::new();
        let user1 = Uuid::new_v4();
        let user2 = Uuid::new_v4();
        let user3 = Uuid::new_v4();
        let (tx1, mut rx1) = mpsc::channel(16);
        let (tx2, mut rx2) = mpsc::channel(16);
        let (tx3, mut rx3) = mpsc::channel(16);

        hub.register(user1, 1, tx1);
        hub.register(user2, 1, tx2);
        hub.register(user3, 1, tx3);

        let members = [user1, user2, user3];
        hub.broadcast_json(&members, r#"{"type":"test"}"#, Some(user2));

        // user1 and user3 receive the message
        let msg1 = rx1.recv().await.unwrap();
        let msg3 = rx3.recv().await.unwrap();
        match (msg1, msg3) {
            (WsMessage::Text(t1), WsMessage::Text(t3)) => {
                assert_eq!(t1.as_str(), r#"{"type":"test"}"#);
                assert_eq!(t3.as_str(), r#"{"type":"test"}"#);
            }
            _ => panic!("Expected Text messages"),
        }

        // user2 (excluded) should not have received anything
        assert!(rx2.try_recv().is_err());
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

    #[tokio::test]
    async fn test_send_returns_false_when_queue_full() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        // Capacity 1, no receiver consumption: second send must fail.
        let (tx, _rx) = mpsc::channel(1);
        hub.register(user_id, 1, tx);

        let first = hub.send_to_device(&user_id, 1, WsMessage::Text("first".into()));
        assert!(first, "first send should fit in capacity-1 queue");

        let second = hub.send_to_device(&user_id, 1, WsMessage::Text("second".into()));
        assert!(
            !second,
            "second send must report failure when queue is full"
        );
    }

    #[tokio::test]
    async fn test_send_returns_false_when_queue_closed() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, rx) = mpsc::channel(4);
        hub.register(user_id, 1, tx);
        drop(rx);

        let sent = hub.send_to_device(&user_id, 1, WsMessage::Text("dropped".into()));
        assert!(!sent, "send must report failure once receiver is dropped");
    }

    #[tokio::test]
    async fn test_slow_consumer_unregisters_after_threshold() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, _rx) = mpsc::channel(1);
        hub.register(user_id, 1, tx);

        // First send fits in the cap-1 queue.
        assert!(hub.send_to_device(&user_id, 1, WsMessage::Text("first".into())));
        // Subsequent sends fail (queue is full and we're not consuming) but
        // the device stays registered until the threshold is crossed.
        for i in 0..(SLOW_CONSUMER_FULL_THRESHOLD - 1) {
            assert!(
                !hub.send_to_device(&user_id, 1, WsMessage::Text("blocked".into())),
                "iteration {i}: send should fail while queue is full"
            );
            assert!(
                hub.inner.connections.contains_key(&user_id),
                "iteration {i}: device should still be registered"
            );
        }
        // The next failure trips the threshold and unregisters the device.
        assert!(!hub.send_to_device(&user_id, 1, WsMessage::Text("kicker".into())));
        assert!(
            !hub.inner.connections.contains_key(&user_id),
            "device must be unregistered after slow-consumer threshold"
        );
    }

    /// Successful sends reset the consecutive-Full counter so a brief burst
    /// of contention doesn't accumulate toward eviction.
    #[tokio::test]
    async fn test_full_counter_resets_on_success() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, mut rx) = mpsc::channel(1);
        hub.register(user_id, 1, tx);

        // Half-fill the failure budget without consuming.
        assert!(hub.send_to_device(&user_id, 1, WsMessage::Text("ok".into())));
        for _ in 0..10 {
            assert!(!hub.send_to_device(&user_id, 1, WsMessage::Text("full".into())));
        }
        // Drain the receiver and send again -- counter must reset.
        let _ = rx.recv().await;
        assert!(hub.send_to_device(&user_id, 1, WsMessage::Text("recovered".into())));
        assert!(
            hub.inner.full_counters.get(&(user_id, 1)).is_none(),
            "successful send must clear the counter"
        );
    }

    #[tokio::test]
    async fn test_send_to_user_partial_success_with_one_full_queue() {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx_full, _rx_full) = mpsc::channel(1);
        let (tx_ok, mut rx_ok) = mpsc::channel(8);

        hub.register(user_id, 1, tx_full.clone());
        hub.register(user_id, 2, tx_ok);

        // Pre-fill device 1's queue.
        tx_full.try_send(WsMessage::Text("filler".into())).unwrap();

        let any_sent = hub.send_to_user(&user_id, WsMessage::Text("payload".into()));
        assert!(
            any_sent,
            "send_to_user should report true when at least one device accepts"
        );

        // Device 2 should still receive it.
        match rx_ok.recv().await.unwrap() {
            WsMessage::Text(t) => assert_eq!(t.as_str(), "payload"),
            _ => panic!("Expected Text"),
        }
    }
}
