use axum::extract::ws::Message as WsMessage;
use criterion::{BenchmarkId, Criterion, criterion_group, criterion_main};
use echo_server::ws::hub::Hub;
use tokio::sync::mpsc;
use uuid::Uuid;

fn bench_hub_register(c: &mut Criterion) {
    let mut group = c.benchmark_group("hub_register");
    let rt = tokio::runtime::Runtime::new().unwrap();

    group.bench_function("single_device", |b| {
        b.iter(|| {
            let hub = Hub::new();
            let (tx, _rx) = mpsc::channel(16);
            hub.register(Uuid::new_v4(), 1, tx);
        });
    });

    // Register N users, then add one more
    for n in [100, 1000, 10000] {
        group.bench_with_input(BenchmarkId::new("with_existing_users", n), &n, |b, &n| {
            let hub = Hub::new();
            let _rxs: Vec<_> = (0..n)
                .map(|_| {
                    let (tx, rx) = mpsc::channel(16);
                    hub.register(Uuid::new_v4(), 1, tx);
                    rx
                })
                .collect();

            b.iter(|| {
                let (tx, _rx) = mpsc::channel(16);
                hub.register(Uuid::new_v4(), 1, tx);
            });
        });
    }

    group.finish();
    drop(rt);
}

fn bench_hub_send(c: &mut Criterion) {
    let mut group = c.benchmark_group("hub_send");
    let _rt = tokio::runtime::Runtime::new().unwrap();

    // send_to_user with 1 device
    group.bench_function("send_to_user_1_device", |b| {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, _rx) = mpsc::channel(4096);
        hub.register(user_id, 1, tx);

        b.iter(|| {
            hub.send_to_user(&user_id, WsMessage::Text("test".into()));
        });
    });

    // send_to_user with 5 devices
    group.bench_function("send_to_user_5_devices", |b| {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let _rxs: Vec<_> = (0..5)
            .map(|i| {
                let (tx, rx) = mpsc::channel(4096);
                hub.register(user_id, i, tx);
                rx
            })
            .collect();

        b.iter(|| {
            hub.send_to_user(&user_id, WsMessage::Text("test".into()));
        });
    });

    // send_to_device (specific device lookup)
    group.bench_function("send_to_device", |b| {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();
        let (tx, _rx) = mpsc::channel(4096);
        hub.register(user_id, 1, tx);

        b.iter(|| {
            hub.send_to_device(&user_id, 1, WsMessage::Text("test".into()));
        });
    });

    // send to offline user (miss path)
    group.bench_function("send_to_offline", |b| {
        let hub = Hub::new();
        let user_id = Uuid::new_v4();

        b.iter(|| {
            hub.send_to_user(&user_id, WsMessage::Text("test".into()));
        });
    });

    group.finish();
}

fn bench_hub_broadcast(c: &mut Criterion) {
    let mut group = c.benchmark_group("hub_broadcast");
    let _rt = tokio::runtime::Runtime::new().unwrap();

    for member_count in [10, 50, 100, 500] {
        group.bench_with_input(
            BenchmarkId::new("broadcast_json", member_count),
            &member_count,
            |b, &n| {
                let hub = Hub::new();
                let member_ids: Vec<Uuid> = (0..n).map(|_| Uuid::new_v4()).collect();
                let _rxs: Vec<_> = member_ids
                    .iter()
                    .map(|uid| {
                        let (tx, rx) = mpsc::channel(4096);
                        hub.register(*uid, 1, tx);
                        rx
                    })
                    .collect();

                let json = r#"{"type":"message","content":"hello"}"#;
                let exclude = Some(member_ids[0]);

                b.iter(|| {
                    hub.broadcast_json(&member_ids, json, exclude);
                });
            },
        );
    }

    group.finish();
}

fn bench_hub_concurrent_lookup(c: &mut Criterion) {
    let mut group = c.benchmark_group("hub_lookup");
    let _rt = tokio::runtime::Runtime::new().unwrap();

    // Measure DashMap lookup speed with many entries
    for n in [100, 1000, 10000] {
        group.bench_with_input(BenchmarkId::new("get_online_ids", n), &n, |b, &n| {
            let hub = Hub::new();
            let _rxs: Vec<_> = (0..n)
                .map(|_| {
                    let (tx, rx) = mpsc::channel(16);
                    hub.register(Uuid::new_v4(), 1, tx);
                    rx
                })
                .collect();

            b.iter(|| hub.get_online_user_ids());
        });
    }

    group.finish();
}

criterion_group!(
    benches,
    bench_hub_register,
    bench_hub_send,
    bench_hub_broadcast,
    bench_hub_concurrent_lookup,
);
criterion_main!(benches);
