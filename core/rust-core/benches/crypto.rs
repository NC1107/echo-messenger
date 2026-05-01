use criterion::{BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use echo_core::crypto::{encrypt, keys, session};
use echo_core::signal::keys::{EphemeralKeyPair, IdentityKeyPair, PreKeyBundle};
use echo_core::signal::ratchet::RatchetState;
use echo_core::signal::session as signal_session;
use echo_core::signal::x3dh;
use rand_core::OsRng;
use x25519_dalek::{PublicKey, StaticSecret};

// ---------------------------------------------------------------------------
// AES-256-GCM
// ---------------------------------------------------------------------------

fn bench_aes_gcm(c: &mut Criterion) {
    let key = [42u8; 32];
    let mut group = c.benchmark_group("aes_gcm");

    for size in [64, 256, 1024, 4096, 10240] {
        let plaintext = vec![0xABu8; size];
        let encrypted = encrypt::encrypt(&key, &plaintext).unwrap();

        group.throughput(Throughput::Bytes(size as u64));

        group.bench_with_input(BenchmarkId::new("encrypt", size), &plaintext, |b, pt| {
            b.iter(|| encrypt::encrypt(&key, pt).unwrap());
        });

        group.bench_with_input(BenchmarkId::new("decrypt", size), &encrypted, |b, ct| {
            b.iter(|| encrypt::decrypt(&key, ct).unwrap());
        });
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// X3DH key exchange (crypto module -- simplified, deprecated)
// ---------------------------------------------------------------------------

#[allow(deprecated)] // benchmarking deprecated helpers for baseline comparison
fn bench_x3dh_crypto(c: &mut Criterion) {
    let mut group = c.benchmark_group("x3dh_crypto");

    let alice_identity = StaticSecret::random_from_rng(OsRng);
    let alice_identity_pub = PublicKey::from(&alice_identity);

    let bob_identity = StaticSecret::random_from_rng(OsRng);
    let bob_identity_pub = PublicKey::from(&bob_identity);

    let bob_spk = StaticSecret::random_from_rng(OsRng);
    let bob_spk_pub = PublicKey::from(&bob_spk);

    let bob_otp = StaticSecret::random_from_rng(OsRng);
    let bob_otp_pub = PublicKey::from(&bob_otp);

    group.bench_function("initiate_with_otp", |b| {
        b.iter(|| {
            session::x3dh_initiate(
                &alice_identity,
                &bob_identity_pub,
                &bob_spk_pub,
                Some(&bob_otp_pub),
            )
            .unwrap()
        });
    });

    group.bench_function("initiate_without_otp", |b| {
        b.iter(|| {
            session::x3dh_initiate(&alice_identity, &bob_identity_pub, &bob_spk_pub, None).unwrap()
        });
    });

    // Pre-compute an initiation result for respond benchmark
    let init_result = session::x3dh_initiate(
        &alice_identity,
        &bob_identity_pub,
        &bob_spk_pub,
        Some(&bob_otp_pub),
    )
    .unwrap();
    let their_ephemeral =
        PublicKey::from(<[u8; 32]>::try_from(init_result.ephemeral_public.as_slice()).unwrap());

    group.bench_function("respond_with_otp", |b| {
        b.iter(|| {
            session::x3dh_respond(
                &bob_identity,
                &bob_spk,
                Some(&bob_otp),
                &alice_identity_pub,
                &their_ephemeral,
            )
            .unwrap()
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// X3DH key exchange (signal module -- full with signatures)
// ---------------------------------------------------------------------------

fn bench_x3dh_signal(c: &mut Criterion) {
    let mut group = c.benchmark_group("x3dh_signal");

    let alice_identity = IdentityKeyPair::generate();
    let bob_identity = IdentityKeyPair::generate();

    let bob_spk_private = StaticSecret::random_from_rng(OsRng);
    let bob_spk_public = PublicKey::from(&bob_spk_private);
    let spk_sig = bob_identity.sign(bob_spk_public.as_bytes());

    let bob_otp_private = StaticSecret::random_from_rng(OsRng);
    let bob_otp_public = PublicKey::from(&bob_otp_private);

    let bundle = PreKeyBundle {
        identity_key: bob_identity.public,
        signed_prekey: bob_spk_public,
        signed_prekey_signature: spk_sig,
        one_time_prekey: Some(bob_otp_public),
    };
    let bob_verifying = bob_identity.verifying_key();

    group.bench_function("initiate_full", |b| {
        b.iter(|| x3dh::initiate(&alice_identity, &bundle, &bob_verifying).unwrap());
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Double Ratchet
// ---------------------------------------------------------------------------

fn bench_ratchet(c: &mut Criterion) {
    let mut group = c.benchmark_group("double_ratchet");

    let shared_secret = [42u8; 32];
    let bob_priv = StaticSecret::random_from_rng(OsRng);
    let bob_pub = PublicKey::from(&bob_priv);

    // Benchmark single-direction encrypt (no DH ratchet steps after init)
    group.bench_function("encrypt_no_dh", |b| {
        let mut alice = RatchetState::init_alice(&shared_secret, &bob_pub).unwrap();
        b.iter(|| alice.encrypt(b"Hello, world!").unwrap());
    });

    // Benchmark decrypt (receiving sequential messages, no DH ratchet)
    group.bench_function("decrypt_no_dh", |b| {
        b.iter_custom(|iters| {
            let mut alice = RatchetState::init_alice(&shared_secret, &bob_pub).unwrap();
            let bob_priv_clone = StaticSecret::from(bob_priv.to_bytes());
            let mut bob = RatchetState::init_bob(&shared_secret, bob_priv_clone).unwrap();

            // Pre-generate messages
            let msgs: Vec<_> = (0..iters)
                .map(|_| alice.encrypt(b"Hello, world!").unwrap())
                .collect();

            let start = std::time::Instant::now();
            for (ct, hdr) in &msgs {
                bob.decrypt(hdr, ct).unwrap();
            }
            start.elapsed()
        });
    });

    // Benchmark ping-pong (every message triggers DH ratchet)
    group.bench_function("encrypt_decrypt_ping_pong", |b| {
        b.iter_custom(|iters| {
            let mut alice = RatchetState::init_alice(&shared_secret, &bob_pub).unwrap();
            let bob_priv_clone = StaticSecret::from(bob_priv.to_bytes());
            let mut bob = RatchetState::init_bob(&shared_secret, bob_priv_clone).unwrap();

            let start = std::time::Instant::now();
            for _ in 0..iters {
                let (ct, hdr) = alice.encrypt(b"ping").unwrap();
                bob.decrypt(&hdr, &ct).unwrap();
                let (ct, hdr) = bob.encrypt(b"pong").unwrap();
                alice.decrypt(&hdr, &ct).unwrap();
            }
            start.elapsed()
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Key generation
// ---------------------------------------------------------------------------

fn bench_keygen(c: &mut Criterion) {
    let mut group = c.benchmark_group("keygen");

    group.bench_function("identity_keypair", |b| {
        b.iter(IdentityKeyPair::generate);
    });

    group.bench_function("ephemeral_keypair", |b| {
        b.iter(EphemeralKeyPair::generate);
    });

    group.bench_function("crypto_identity_keypair", |b| {
        b.iter(keys::IdentityKeyPair::generate);
    });

    let identity = keys::IdentityKeyPair::generate();
    group.bench_function("signed_prekey", |b| {
        b.iter(|| keys::generate_signed_prekey(&identity, 1));
    });

    group.bench_function("one_time_prekeys_10", |b| {
        b.iter(|| keys::generate_one_time_prekeys(0, 10));
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Full session lifecycle
// ---------------------------------------------------------------------------

fn bench_session_lifecycle(c: &mut Criterion) {
    let mut group = c.benchmark_group("session_lifecycle");

    group.bench_function("create_and_accept", |b| {
        b.iter(|| {
            let alice_id = IdentityKeyPair::generate();
            let bob_id = IdentityKeyPair::generate();

            let bob_spk_priv = StaticSecret::random_from_rng(OsRng);
            let bob_spk_pub = PublicKey::from(&bob_spk_priv);
            let spk_sig = bob_id.sign(bob_spk_pub.as_bytes());

            let bundle = PreKeyBundle {
                identity_key: bob_id.public,
                signed_prekey: bob_spk_pub,
                signed_prekey_signature: spk_sig,
                one_time_prekey: None,
            };

            let bob_verifying = bob_id.verifying_key();
            let (mut alice_session, initial_msg) =
                signal_session::create_session(&alice_id, "bob", &bundle, &bob_verifying).unwrap();
            let mut bob_session =
                signal_session::accept_session(&bob_id, &bob_spk_priv, None, "alice", &initial_msg)
                    .unwrap();

            let wire = signal_session::encrypt_message(&mut alice_session, b"Hello Bob!").unwrap();
            signal_session::decrypt_message(&mut bob_session, &wire).unwrap();
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_aes_gcm,
    bench_x3dh_crypto,
    bench_x3dh_signal,
    bench_ratchet,
    bench_keygen,
    bench_session_lifecycle,
);
criterion_main!(benches);
