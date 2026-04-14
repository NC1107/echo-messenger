# Learning Guide: Improving an Encrypted Chat App (Rust Axum + Flutter)

**Generated**: 2026-04-11
**Sources**: 42 resources analyzed
**Depth**: deep
**Context**: Echo Messenger -- Rust Axum server, Flutter client, Signal Protocol E2E encryption

## Prerequisites

- Familiarity with Rust async programming (Tokio, Axum)
- Flutter/Dart state management (Riverpod)
- Signal Protocol basics (X3DH, Double Ratchet)
- PostgreSQL and WebSocket fundamentals
- Docker deployment experience

## TL;DR

- Replace sequential DB queries with batched operations and CTEs to cut message handling latency 50-80%
- Add a pub/sub backplane (NATS JetStream or Redis) between WebSocket instances to enable horizontal scaling
- Move crypto operations to Dart isolates to prevent UI jank; use long-lived isolates for session management
- Implement Tower middleware composition for rate limiting, circuit breaking, and observability as composable layers
- Adopt OpenTelemetry with tracing-opentelemetry for distributed tracing, metrics, and structured logging in one pipeline

---

## 1. Performance: Message Delivery Optimization

### 1.1 Database Query Batching

**Problem**: Sequential DB queries per message (5-6 round trips) create cumulative latency. Even 5ms queries compound to 2+ second page loads with 50+ separate calls.

**Solution**: Batch related queries using PostgreSQL CTEs and `IN` clauses.

```sql
-- Instead of 5 separate queries per message send:
-- 1. Validate sender, 2. Check recipient, 3. Insert message,
-- 4. Update conversation, 5. Fetch delivery info

-- Use a single CTE chain:
WITH validated AS (
    SELECT id, username FROM users WHERE id = $1
),
inserted AS (
    INSERT INTO messages (sender_id, recipient_id, content, encrypted_content)
    SELECT v.id, $2, $3, $4 FROM validated v
    RETURNING id, created_at
),
conv_updated AS (
    UPDATE conversations SET last_message_at = NOW(), message_count = message_count + 1
    WHERE id = $5
    RETURNING id
)
SELECT i.id, i.created_at, v.username
FROM inserted i, validated v;
```

**Impact**: Mattermost achieved 1000x query speedups through targeted indexing and query restructuring. For chat apps, compound indexes on `(conversation_id, created_at)` and `(user_id, is_read)` are critical.

**Connection Pooling**: Configure SQLx pool properly:
```rust
PgPoolOptions::new()
    .max_connections(25)          // Match PgBouncer default_pool_size
    .min_connections(5)           // Pre-warm for consistent latency
    .max_lifetime(Duration::from_secs(1800))  // Prevent stale connections
    .idle_timeout(Duration::from_secs(600))
    .acquire_timeout(Duration::from_secs(5))
```

Without pooling: connection (50-100ms) + query (5ms) + disconnect. With pooling: acquire (0.1ms) + query (5ms) + return. Monitor cache hit ratio targeting >95%.

Source: [PostgreSQL Performance Tuning](https://last9.io/blog/postgresql-performance/), [SQLx Connection Pooling](https://docs.rs/sqlx/latest/sqlx/struct.Pool.html)

### 1.2 Discord's Scaling Architecture

Discord handles billions of messages daily through several key patterns:

- **Guild Process Model**: Each community has a dedicated process tracking connected users. When a message arrives, it fans out to relevant session processes via WebSocket.
- **Passive Connections**: Over 90% of user-guild connections are "passive" (guilds users aren't viewing), reducing processing load by an equivalent margin.
- **Relay Distribution**: For large communities, relays distribute fanout across multiple processes, each handling up to 15,000 users.
- **Worker Offload**: Slow member iterations are offloaded to async workers using in-memory databases (ETS equivalent).

**Applicable Pattern for Echo**: Implement passive subscriptions where clients not actively viewing a conversation receive only notification-level updates (unread count, typing indicator) rather than full message payloads.

Source: [Discord Architecture](https://blog.bytebytego.com/p/how-discord-serves-15-million-users), [Discord Elixir Scaling](https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users)

### 1.3 DashMap Optimization

DashMap uses sharding internally (one shard per CPU core) with `Box<[RwLock<HashMap<K, V>>]>`. For Echo's WebSocket hub:

- **Current use case is appropriate**: With hundreds to low thousands of connections, DashMap is optimal. `scc::HashMap` only outperforms at 2000+ entries per CPU core.
- **Whirlwind** is an async-native alternative that performs better in read-heavy workloads with Tokio green threading.
- **Papaya** offers lock-free reads for extremely high-concurrency scenarios.

The sharding count is determined at runtime by CPU core count. DashMap reserves the top 7 hash bits for SwissTable SIMD tag (H2) operations.

Source: [DashMap GitHub](https://github.com/xacrimon/dashmap), [Concurrent Map Comparison](https://github.com/wvwwvwwv/scalable-concurrent-containers/discussions/113)

---

## 2. Architecture: Horizontal Scaling and Message Queues

### 2.1 Pub/Sub Backplane with NATS

**Why NATS over Redis Pub/Sub for Echo**: NATS provides a unified platform combining pub/sub, persistent streaming (JetStream), key-value store, and request-reply in a single binary with zero external dependencies.

**Architecture**:
```
Client A -> WS Server 1 -> NATS (chat.{conv_id}.messages) -> WS Server 2 -> Client B
                              |
                         JetStream (durable)
                              |
                         KV Store (user sessions, typing state)
```

**Subject Naming Convention**:
```
chat.{conversation_id}.messages    # Message delivery
chat.{conversation_id}.typing      # Typing indicators
presence.{user_id}                 # Online/offline status
keys.{user_id}.prekey              # Signal Protocol prekey bundles
```

**Queue Groups** for load distribution: Multiple server instances subscribe to the same queue group, and NATS automatically distributes messages so only one instance processes each message -- critical for avoiding duplicate message delivery.

**JetStream for Persistence**:
- Durable consumers maintain offset state across server restarts
- Exactly-once semantics via message ID deduplication
- Replay capability for message history sync
- Retention policies by time, byte limit, or message count

Source: [NATS as Cloud-Native Backbone](https://dev.to/thedonmon/beyond-kafka-and-redis-a-practical-guide-to-nats-as-your-unified-cloud-native-backbone-4g86), [NATS Docs](https://docs.nats.io/nats-concepts/core-nats/queue)

### 2.2 WebSocket Horizontal Scaling

**The Core Problem**: WebSocket connections are stateful. A single server instance only knows about its own connected clients.

**Solution Stack**:
1. **Load Balancer** (Traefik/HAProxy): Use `leastconn` algorithm for WebSocket traffic (not round-robin), since some connections are more resource-intensive
2. **Sticky Sessions** (short-term): Cookie-based session affinity during initial scaling phase
3. **External State** (long-term): Move session state to Redis/NATS KV so any server can handle any reconnecting client
4. **Pub/Sub Backplane**: All instances publish messages to NATS/Redis; each instance forwards to its local clients

**Scaling Thresholds**: A properly tuned server handles 500K+ idle WebSocket connections with 16GB RAM (2-10KB per connection). Scale at 70-80% capacity. Monitor p99 latency -- rising p99 indicates bottleneck before throughput drops.

**Consistent Hashing** for connection distribution: Adding/removing servers only redistributes connections mapped to the affected node, not all connections.

Source: [WebSockets at Scale](https://websocket.org/guides/websockets-at-scale/), [How to Scale WebSocket](https://tsh.io/blog/how-to-scale-websocket)

### 2.3 CQRS for Chat

CQRS separates write (command) and read (query) paths:

- **Write side**: Message encryption, validation, storage in append-only event log
- **Read side**: Materialized views optimized for conversation timeline, search, unread counts

The `cqrs-es` Rust crate provides a lightweight framework using SQLx under the hood. For chat, events include `MessageSent`, `MessageDelivered`, `MessageRead`, `ReactionAdded`, `TypingStarted`.

**When to adopt**: CQRS adds complexity. Adopt only when read/write patterns diverge significantly (many readers, few writers per conversation) or when you need complete audit trails.

Source: [CQRS and Event Sourcing in Rust](https://doc.rust-cqrs.org/), [cqrs-es crate](https://crates.io/crates/cqrs-es)

---

## 3. Security Hardening

### 3.1 Signal Protocol: Post-Quantum Upgrade Path

Signal released the **Triple Ratchet protocol** (October 2025), extending Double Ratchet with the Sparse Post-Quantum Ratchet (SPQR):

- **Hybrid security**: Keys from both elliptic-curve DH ratchet and ML-KEM post-quantum ratchet are mixed via KDF. An attacker must break both schemes.
- **PQXDH handshake**: Adds only ~1-3ms overhead on mobile devices. Uses ML-KEM-1024 combined with X25519.
- **Chunking with erasure codes**: ML-KEM public keys (1184 bytes) are ~35x larger than classical counterparts. SPQR breaks them into 42-byte chunks with erasure coding for reliable delivery.
- **Performance trade-off**: Post-quantum PCS (post-compromise security) recovery is slower than classical ratchet due to chunking overhead.

**Implementation Priority for Echo**: Start with PQXDH for key exchange (the handshake). Full Triple Ratchet requires significant protocol complexity. Monitor NIST PQC standardization timeline.

Source: [Signal Triple Ratchet](https://signal.org/blog/spqr/), [PQShield Analysis](https://pqshield.com/diving-into-signals-new-pq-protocol/), [Signal PQXDH Spec](https://signal.org/docs/specifications/pqxdh/)

### 3.2 Sealed Sender Implementation

Signal's sealed sender hides the sender's identity from the server:

1. Client obtains a **short-lived sender certificate** (phone number, public identity key, expiration)
2. Message is encrypted with Signal Protocol as usual
3. Envelope (sender cert + ciphertext) is encrypted using sender+recipient identity keys via HKDF
4. Envelope is sent **without authentication**, using only a **96-bit delivery token** derived from the recipient's profile key
5. Server routes based on delivery token without seeing sender identity

**Abuse Prevention**: Delivery tokens require knowledge of profile key (shared only with contacts). Blocking a user triggers profile key rotation.

**Applicability to Echo**: This pattern eliminates sender metadata from server logs. Implement after core encryption is stable.

Source: [Signal Sealed Sender](https://signal.org/blog/sealed-sender/), [Improving Sealed Sender (UMD)](https://www.cs.umd.edu/~kaptchuk/publications/ndss21.pdf)

### 3.3 Key Transparency

Signal maintains an **auditable key directory** using Merkle tree-based transparency logs:

- Server keeps a verifiable log of all public key changes
- Third-party auditor (Java/Micronaut) verifies prefix tree and log tree integrity
- VRF (Verifiable Random Function) blinds lookup queries, hiding who queries whose keys
- Protocol binds X25519 identity key to public identifier

Meta deployed similar key transparency for WhatsApp using the `akd` (Auditable Key Directory) library, with Cloudflare providing independent auditing.

Source: [Signal Key Transparency Server](https://github.com/signalapp/key-transparency-server), [Key Transparency at Meta](https://engineering.fb.com/2025/11/20/security/key-transparency-comes-to-messenger/)

### 3.4 Certificate Pinning in Flutter

**SPKI Hash Pinning** (recommended over full cert pinning):

```dart
// Pin public key fingerprint, not the certificate itself
final context = SecurityContext(withTrustedRoots: false);
context.setTrustedCertificatesBytes(certBytes);

final dio = Dio();
final adapter = DefaultHttpClientAdapter();
adapter.onHttpClientCreate = (_) => HttpClient(context: context);
dio.httpClientAdapter = adapter;
```

**Best Practices**:
- Pin SPKI hashes, not static certificates -- survives cert rotation
- Include both current and next certificate during rotation periods
- Extract PEM via: `openssl s_client -connect api.example.com:443 -showcerts`
- Test on real devices (emulators may bypass pinning)
- Consider `http_security_pinning` package for hash-based pinning

**Rotation Strategy**: Use Firebase Remote Config or similar for hot-updating pinned hashes without app updates.

Source: [Flutter SSL Pinning with Dio](https://vibe-studio.ai/insights/certificate-pinning-in-flutter-with-dio), [SSL Pinning Guide](https://dev.to/harsh8088/implementing-ssl-pinning-in-flutter-3e8a)

---

## 4. Flutter Optimization

### 4.1 Isolate-Based Crypto

**Core Rule**: Use isolates when computation exceeds Flutter's frame gap (16.67ms at 60Hz). Signal Protocol encryption/decryption qualifies.

**Long-Lived Isolate for Crypto Worker**:
```dart
// Spawn once, reuse for all crypto operations
late final SendPort _cryptoPort;

Future<void> initCryptoWorker() async {
  final receivePort = ReceivePort();
  final rootToken = RootIsolateToken.instance!;
  await Isolate.spawn(_cryptoIsolateMain, (receivePort.sendPort, rootToken));
  _cryptoPort = await receivePort.first as SendPort;
}

void _cryptoIsolateMain((SendPort, RootIsolateToken) args) {
  final (sendPort, rootToken) = args;
  BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);

  final port = ReceivePort();
  sendPort.send(port.sendPort);

  port.listen((message) {
    // Handle encrypt/decrypt requests
    // Access platform channels (secure storage) via rootToken
  });
}
```

**Key Considerations**:
- `Isolate.run()` for one-off operations; long-lived isolates for repeated crypto
- Immutable objects are referenced (not copied) between isolates -- use immutable key material
- Web platform: isolates not supported; `compute()` runs on main thread
- Cannot access `rootBundle` in spawned isolates; load assets on main thread first

Source: [Flutter Isolates](https://docs.flutter.dev/perf/isolates), [Flutter Background Processing](https://mobisoftinfotech.com/resources/blog/flutter-development/flutter-isolates-background-processing)

### 4.2 Efficient Chat List Rendering

**ListView.builder is mandatory** for chat messages -- builds only visible widgets:
```dart
ListView.builder(
  reverse: true,  // Chat: newest at bottom
  itemExtent: 72, // Fixed height = massive perf win (scrolling can pre-calculate)
  itemCount: messages.length,
  itemBuilder: (context, index) => MessageBubble(messages[index]),
)
```

**Advanced Optimizations**:
- Use `SliverList` with `SliverChildBuilderDelegate` for mixed content (text, images, system messages)
- Set `addAutomaticKeepAlives: false` for messages that don't need state preservation
- Use `itemExtentBuilder` for variable-height items (still faster than unconstrained)
- Cache decrypted message content to avoid re-decryption on scroll

Source: [Flutter ListView Performance](https://docs.flutter.dev/cookbook/lists/long-lists), [ListView Optimization](https://medium.com/my-technical-journey/lesser-known-techniques-to-improve-listview-performance-in-flutter-7ab28b4e4c8c)

### 4.3 Offline-First Architecture

Flutter's official offline-first pattern uses a **repository layer** combining local and remote sources:

```dart
class MessageRepository {
  final ApiClient _api;
  final LocalDatabase _db;

  Stream<List<Message>> getMessages(String conversationId) async* {
    // 1. Emit cached messages immediately
    yield await _db.getMessages(conversationId);

    // 2. Fetch fresh from server, update cache
    try {
      final remote = await _api.getMessages(conversationId);
      await _db.upsertMessages(remote);
      yield remote;
    } catch (e) {
      // Already yielded cached data, graceful offline fallback
    }
  }

  Future<void> sendMessage(Message msg) async {
    // Optimistic: save locally with synchronized=false
    await _db.insertMessage(msg.copyWith(synchronized: false));

    try {
      await _api.sendMessage(msg);
      await _db.markSynchronized(msg.id);
    } catch (e) {
      // Will retry on next sync cycle
    }
  }
}
```

**Sync Strategy**: Use `workmanager` for background sync, `connectivity_plus` for network detection, and a sync flag on each record. Timer-based polling (every 5 minutes) works for most cases.

**Hybrid Storage**: Hive for ephemeral data (typing indicators, presence), Drift/SQLite for core entities (messages, conversations, contacts).

Source: [Flutter Offline-First](https://docs.flutter.dev/app-architecture/design-patterns/offline-first), [Offline-First Blueprint](https://geekyants.com/blog/offline-first-flutter-implementation-blueprint-for-real-world-apps)

### 4.4 Riverpod Best Practices

**Critical Anti-Patterns**:
- Never use `ref.read` in `build` methods (prevents updates)
- Never use `ref.watch` outside `build` methods (wasteful subscriptions)
- Always check `ref.mounted` after async operations before accessing `state`
- Never cache notifier references across async gaps (stale references)

**Performance**:
- Use `select()` for fine-grained rebuild control: `ref.watch(chatProvider.select((s) => s.unreadCount))`
- Use `autoDispose` for conversation-scoped providers
- Migrate from `StateNotifier` to `Notifier`/`AsyncNotifier` (Riverpod 3.0)
- Keep notifier properties private; expose logic through `state` only

Source: [Riverpod Best Practices](https://dcm.dev/blog/2026/03/25/inside-riverpod-source-code-guide-dcm-rules/), [Riverpod 3.0 Migration](https://riverpod.dev/docs/3.0_migration)

---

## 5. Rust Server Patterns

### 5.1 Tower Middleware Composition

Stack middleware layers for comprehensive request handling:

```rust
use tower::ServiceBuilder;
use tower_http::{cors::CorsLayer, trace::TraceLayer, compression::CompressionLayer};

let app = Router::new()
    .route("/api/messages", post(send_message))
    .layer(
        ServiceBuilder::new()
            .layer(TraceLayer::new_for_http())        // Outermost: logs all requests
            .layer(CompressionLayer::new())            // Compress responses
            .layer(CorsLayer::permissive())            // CORS handling
            .layer(RateLimitLayer::new(100, Duration::from_secs(60)))  // Rate limit
            .layer(TimeoutLayer::new(Duration::from_secs(30)))         // Request timeout
    );
```

**Execution Order**: First added = outermost layer. Requests flow: Trace -> Compression -> CORS -> RateLimit -> Timeout -> Handler, then responses flow back in reverse.

**Circuit Breaker** (`tower-circuitbreaker`): Three states -- Closed (normal), Open (after failures, returns fallback), Half-Open (allows test requests after cooldown). Use for external service calls (LiveKit, FCM).

**Resilience Stack**: Client-side: timeout -> circuit breaker -> retry. Server-side: rate limit -> bulkhead -> timeout.

Source: [Tower Middleware for Axum](https://medium.com/@khalludi123/creating-a-rate-limiter-middleware-using-tower-for-axum-rust-be1d65fbeca), [Tower Documentation](https://docs.rs/tower)

### 5.2 Distributed Rate Limiting

Replace in-memory rate limiting with Redis-backed sliding window:

```rust
// Lua script for atomic sliding window rate limit
const RATE_LIMIT_SCRIPT: &str = r#"
    local key = KEYS[1]
    local window = tonumber(ARGV[1])
    local limit = tonumber(ARGV[2])
    local now = tonumber(ARGV[3])

    redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
    local count = redis.call('ZCARD', key)

    if count < limit then
        redis.call('ZADD', key, now, now .. '-' .. math.random())
        redis.call('EXPIRE', key, window)
        return 1
    end
    return 0
"#;
```

**Algorithm Selection**:
- **Token bucket**: Best for bursty traffic (mobile apps batch requests on launch)
- **Sliding window**: Best default for API rate limiting (near-exact accuracy, low memory)
- Use Lua scripts in Redis for atomic operations (prevents race conditions)
- The `governor` crate provides pure-Rust token bucket/sliding window for fallback

**Graceful failure**: When Redis is unavailable, fall back to in-memory rate limiting rather than blocking requests entirely.

Source: [Distributed Rate Limiter Redis Rust](https://oneuptime.com/blog/post/2026-01-25-distributed-rate-limiter-redis-rust/view), [Redis Rate Limiting](https://redis.io/tutorials/howtos/ratelimiting/)

### 5.3 Async Task Management and Graceful Shutdown

Tokio graceful shutdown has three phases:

1. **Detect**: `tokio::signal::ctrl_c()` or custom shutdown triggers via mpsc channel
2. **Signal**: `CancellationToken` (all clones share state; cancelling one cancels all)
3. **Wait**: `TaskTracker` from tokio-util resolves when all contained futures complete

```rust
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;

let token = CancellationToken::new();
let tracker = TaskTracker::new();

// Spawn tasks with cancellation awareness
tracker.spawn({
    let token = token.clone();
    async move {
        tokio::select! {
            _ = token.cancelled() => {
                // Flush pending messages, close DB connections
                tracing::info!("WebSocket hub shutting down gracefully");
            }
            _ = run_websocket_hub() => {}
        }
    }
});

// On shutdown signal
token.cancel();
tracker.close();
tracker.wait().await;  // Wait for all tasks to complete cleanup
```

Source: [Tokio Graceful Shutdown](https://tokio.rs/tokio/topics/shutdown), [Cancellation Patterns](https://cybernetist.com/2024/04/19/rust-tokio-task-cancellation-patterns/)

### 5.4 Refactoring God Classes

For 1500-line god classes, use incremental extraction:

1. **Identify natural boundaries**: Separate WebSocket handling, message processing, presence tracking, typing indicators
2. **Extract trait interfaces**: Define behavior contracts before splitting
3. **Create submodules**: `ws/hub.rs` -> `ws/hub/mod.rs`, `ws/hub/routing.rs`, `ws/hub/presence.rs`, `ws/hub/typing.rs`
4. **Use workspace crates** for clean architecture: `api` -> `domain` <- `infrastructure`

**Principle**: Depend on traits, keep database/framework specifics out of domain logic. Don't restructure everything at once -- incremental improvements are more sustainable.

Source: [Rust Project Structure](https://reintech.io/blog/rust-project-structure-best-practices-large-applications), [Rust Web Services Structure](https://blog.logrocket.com/best-way-structure-rust-web-services/)

---

## 6. Observability

### 6.1 OpenTelemetry for Rust

Use `tracing` + `tracing-opentelemetry` for unified observability:

```rust
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};
use tracing_opentelemetry::OpenTelemetryLayer;

// Setup: traces, metrics, and logs through one pipeline
tracing_subscriber::registry()
    .with(EnvFilter::from_default_env())
    .with(tracing_subscriber::fmt::layer())              // Console output
    .with(OpenTelemetryLayer::new(tracer))                // OTLP export
    .init();
```

**Three Signals**:
- **Traces**: Distributed request tracing via `tracing::instrument` macro
- **Metrics**: `opentelemetry-prometheus` for connection counts, message latency histograms
- **Logs**: `OpenTelemetryTracingBridge` converts `tracing` events to OTel LogRecords

**Production Requirements**:
- Manual instrumentation required (Rust has no auto-instrumentation agents)
- Use batch export to reduce overhead
- Set `OTEL_RESOURCE_ATTRIBUTES` for service identification
- Export via gRPC (OTLP) with TLS to SigNoz, Jaeger, or Grafana Tempo

Source: [OpenTelemetry Rust](https://opentelemetry.io/docs/languages/rust/), [SigNoz OpenTelemetry Rust](https://signoz.io/blog/opentelemetry-rust/)

### 6.2 Key Metrics for Chat Apps

Monitor with Prometheus + Grafana:

| Metric | Type | Alert Threshold |
|--------|------|----------------|
| `ws_active_connections` | Gauge | >70% capacity |
| `messages_per_second` | Counter/Rate | Baseline deviation >2x |
| `message_delivery_latency_ms` | Histogram (p50/p95/p99) | p99 > 500ms |
| `ws_reconnection_rate` | Counter/Rate | >5% per minute |
| `db_query_duration_ms` | Histogram | p95 > 100ms |
| `crypto_operation_duration_ms` | Histogram | p99 > 50ms |
| `memory_per_connection_bytes` | Gauge | >64KB avg |

**Baseline Thresholds**: Connection time <100ms, message latency <50ms at p95, <64MB memory per 10,000 connections.

Source: [WebSocket Monitoring](https://www.dotcom-monitor.com/blog/websocket-monitoring/), [Rocket.Chat Metrics](https://github.com/RocketChat/Rocket.Chat.Metrics)

---

## 7. Testing

### 7.1 Property-Based Testing for Crypto

Use `proptest` to verify cryptographic invariants:

```rust
use proptest::prelude::*;

proptest! {
    #[test]
    fn encrypt_decrypt_roundtrip(plaintext in prop::collection::vec(any::<u8>(), 0..10000)) {
        let (alice_session, bob_session) = establish_session();
        let ciphertext = alice_session.encrypt(&plaintext);
        let decrypted = bob_session.decrypt(&ciphertext);
        prop_assert_eq!(plaintext, decrypted);
    }

    #[test]
    fn ratchet_forward_secrecy(messages in prop::collection::vec(any::<Vec<u8>>(), 1..100)) {
        // After N messages, compromising current keys cannot decrypt previous messages
        let (mut alice, mut bob) = establish_session();
        let mut ciphertexts = Vec::new();

        for msg in &messages {
            ciphertexts.push(alice.encrypt(msg));
            let _ = bob.decrypt(ciphertexts.last().unwrap());
        }

        // Compromise current state
        let compromised_bob = bob.clone();
        // Verify previous ciphertexts cannot be decrypted with compromised state
        for ct in &ciphertexts[..ciphertexts.len()-1] {
            prop_assert!(compromised_bob.decrypt_with_old_keys(ct).is_err());
        }
    }
}
```

**Key Properties to Test**:
- Encrypt/decrypt roundtrip for arbitrary plaintexts
- Message ordering independence (Double Ratchet handles out-of-order)
- Forward secrecy (old keys cannot decrypt new messages)
- Key derivation determinism (same inputs produce same keys)

**Combine with Fuzzing**: `cargo-fuzz` with `libFuzzer` explores input space; proptest validates behavioral properties. Use `bolero` to integrate both.

Source: [Proptest](https://github.com/proptest-rs/proptest), [Property-Based Testing in Rust](https://www.lpalmieri.com/posts/an-introduction-to-property-based-testing-in-rust/)

### 7.2 WebSocket Load Testing

**k6** (recommended for modern teams):
```javascript
import ws from 'k6/ws';
import { check } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 100 },    // Ramp to 100 users
    { duration: '1m', target: 100 },     // Steady state
    { duration: '30s', target: 500 },    // Ramp to 500
    { duration: '2m', target: 500 },     // Sustained load
    { duration: '30s', target: 0 },      // Ramp down
  ],
};

export default function () {
  const url = 'wss://echo-messenger.us/ws?ticket=...';
  const res = ws.connect(url, {}, (socket) => {
    socket.on('open', () => {
      socket.send(JSON.stringify({ type: 'message', content: 'test' }));
    });
    socket.on('message', (msg) => {
      check(msg, { 'message received': (m) => m.length > 0 });
    });
    socket.setTimeout(() => socket.close(), 60000);
  });
  check(res, { 'connected successfully': (r) => r && r.status === 101 });
}
```

**Key Metrics**: Connection establishment <100ms, message latency <50ms at p95, reconnection rate <5% per minute, memory <64MB per 10K connections.

Source: [k6 WebSocket Docs](https://grafana.com/docs/k6/latest/using-k6/protocols/websockets/), [WebSocket Performance Testing](https://yrkan.com/blog/websocket-performance-testing/)

### 7.3 E2E Testing Encrypted Messaging

**Verification Methods**:
- **Safety numbers**: Display 60-digit fingerprint derived from both parties' identity keys
- **QR code scanning**: Physical co-presence verification
- **Automated verification**: Test that encrypt(Alice->Bob) followed by decrypt(Bob) produces original plaintext through the full network stack

**Test Strategy**: Run two client instances (`scripts/demo_two_apps.sh`) exchanging messages. Verify at each layer: plaintext in -> encrypted on wire -> plaintext out. Use Playwright/integration tests to validate the full flow.

Source: [Signal Fingerprint Verification](https://signal.org/docs/), [E2E Chat Testing](https://medium.com/@siddhantshelake/end-to-end-encryption-e2ee-in-chat-applications-a-complete-guide-12b226cae8f8)

---

## 8. Mobile-Specific Optimization

### 8.1 Android Battery and Background Processing

**Doze Mode** defers background CPU and network access when the device is unused. **App Standby Buckets** (5 tiers) prioritize apps by recent usage.

**Critical Guideline**: Use FCM (Firebase Cloud Messaging) for message delivery notifications, NOT persistent WebSocket connections. FCM is optimized for Doze mode and App Standby.

**WorkManager** for background sync: Recent research shows 94.3% task completion under restrictive battery conditions vs 47.6% for AlarmManager.

**Push Notification Reliability**:
- Use **high priority** FCM messages for chat notifications (wakes device from Doze)
- Handle foreground notifications with `flutter_local_notifications` (FCM doesn't show in foreground)
- Force-quit by user: messages must wait until app is manually reopened
- Combine `flutter_local_notifications` foreground service with notification channels for persistent indicators

Source: [Android Doze Optimization](https://developer.android.com/training/monitoring-device-state/doze-standby), [Flutter FCM](https://firebase.google.com/docs/cloud-messaging/flutter/receive-messages)

### 8.2 Notification Channels

```dart
// Create channels for different notification types
const chatChannel = AndroidNotificationChannel(
  'chat_messages',
  'Chat Messages',
  importance: Importance.high,
  sound: RawResourceAndroidNotificationSound('message_sound'),
);

const callChannel = AndroidNotificationChannel(
  'voice_calls',
  'Voice Calls',
  importance: Importance.max,  // Full-screen intent for calls
  sound: RawResourceAndroidNotificationSound('ringtone'),
);
```

**Foreground Service**: For ongoing calls or active file transfers, use a foreground service with persistent notification. Set `setOngoing(true)` and ensure the service is not marked as completed to prevent dismissal.

Source: [Notification Channels](https://medium.com/@ChanakaDev/android-channels-in-flutter-003907b151e5), [Flutter Local Notifications](https://pub.dev/packages/flutter_local_notifications)

### 8.3 Deep Linking with GoRouter

```dart
// GoRouter deep link configuration
final router = GoRouter(
  routes: [
    GoRoute(
      path: '/chat/:conversationId',
      builder: (context, state) => ChatScreen(
        conversationId: state.pathParameters['conversationId']!,
      ),
    ),
  ],
);

// AndroidManifest.xml
// <intent-filter android:autoVerify="true">
//   <action android:name="android.intent.action.VIEW" />
//   <data android:scheme="https" android:host="echo-messenger.us" />
// </intent-filter>
```

**Setup Requirements**:
- Host `assetlinks.json` (Android) and `apple-app-site-association` (iOS) at domain root
- Use `app_links` package for handling both Universal Links and App Links
- Note: GoRouter deep links behave like `context.go()` (replaces stack), not `context.push()`

Source: [Flutter Deep Links](https://codewithandrea.com/articles/flutter-deep-links/), [Flutter App Links](https://docs.flutter.dev/cookbook/navigation/set-up-app-links)

---

## Common Pitfalls

| Pitfall | Why It Happens | How to Avoid |
|---------|---------------|--------------|
| Sequential DB queries per message | Each operation has its own await | Batch with CTEs, use `IN` clauses |
| In-memory rate limiting resets on restart | No persistence layer | Use Redis-backed sliding window |
| Crypto on main thread causes jank | Signal Protocol ops take >16ms | Move to long-lived Dart isolate |
| WebSocket single point of failure | No pub/sub backplane | Add NATS/Redis between instances |
| Certificate pinning breaks on rotation | Pinning full cert, not SPKI hash | Pin public key hashes instead |
| Riverpod ref.read in build method | Misunderstanding watch vs read | Always use watch in build |
| N+1 queries for message loading | Fetching related data per message | Batch related queries, use JOINs |
| FCM silent in foreground | Platform default behavior | Use flutter_local_notifications |
| Stale isolate references | Caching ref across async gaps | Re-read ref after every await |
| God class accumulation | Incremental feature additions | Extract to submodules early |

## Best Practices Summary

1. **Database**: Batch queries with CTEs, index on (conversation_id, created_at), pool connections with min 5 pre-warmed
2. **Architecture**: Add pub/sub backplane before scaling horizontally; NATS JetStream for persistence + messaging in one
3. **Security**: PQXDH first, sealed sender second, key transparency third; pin SPKI hashes not certificates
4. **Flutter**: Long-lived isolates for crypto, ListView.builder with itemExtent, offline-first with sync flags
5. **Rust Server**: Tower middleware composition, CancellationToken for shutdown, extract god classes incrementally
6. **Observability**: OpenTelemetry + tracing-opentelemetry for unified telemetry, Prometheus for metrics, 5 key dashboard panels
7. **Testing**: proptest for crypto invariants, k6 for WebSocket load, two-client E2E for encryption verification
8. **Mobile**: FCM for notifications (not persistent WS), WorkManager for background sync, notification channels per message type

## Further Reading

| Resource | Type | Why Recommended |
|----------|------|-----------------|
| [Signal Protocol Specifications](https://signal.org/docs/) | Docs | Official protocol reference |
| [NATS Documentation](https://docs.nats.io/) | Docs | Message queue architecture |
| [Tokio Graceful Shutdown](https://tokio.rs/tokio/topics/shutdown) | Guide | Production async patterns |
| [Flutter Offline-First](https://docs.flutter.dev/app-architecture/design-patterns/offline-first) | Docs | Official architecture pattern |
| [Tower Documentation](https://docs.rs/tower) | Docs | Middleware composition |
| [OpenTelemetry Rust](https://opentelemetry.io/docs/languages/rust/) | Docs | Observability setup |
| [WebSockets at Scale](https://websocket.org/guides/websockets-at-scale/) | Guide | Scaling architecture |
| [Proptest](https://github.com/proptest-rs/proptest) | Library | Property-based testing |
| [k6 WebSocket Testing](https://grafana.com/docs/k6/latest/using-k6/protocols/websockets/) | Docs | Load testing |
| [Discord Architecture](https://blog.bytebytego.com/p/how-discord-serves-15-million-users) | Blog | Real-world scaling patterns |
| [Signal Sealed Sender](https://signal.org/blog/sealed-sender/) | Blog | Metadata protection |
| [cqrs-es Rust](https://doc.rust-cqrs.org/) | Docs | CQRS/Event Sourcing in Rust |

---

*This guide was synthesized from 42 sources. See `resources/improving-encrypted-chat-app-sources.json` for full source list with quality scores.*
