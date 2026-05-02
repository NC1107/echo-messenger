part of '../crypto_service.dart';

/// One-time-prekey generation, persistence, and replenishment helpers
/// extracted from [CryptoService]. The actual key generation
/// (`X25519.newKeyPair`) is unchanged and the persisted-counter logic still
/// guards against key-ID collisions exactly as it did before.
extension CryptoServiceOtp on CryptoService {
  /// Generate 10 new OTP key pairs with monotonically increasing IDs.
  ///
  /// Uses a persisted counter ([_otpNextIdPref]) so that IDs never collide
  /// with previously uploaded keys. This prevents the critical bug where
  /// re-using IDs 0-9 on every upload causes the server to keep old public
  /// keys (via ON CONFLICT DO NOTHING) while the client overwrites local
  /// private keys with new material.
  Future<void> _generateAndPersistOtpKeys(
    List<Map<String, dynamic>> otps,
  ) async {
    final store = SecureKeyStore.instance;

    // Read persisted counter (default 0 for first-ever upload)
    int nextId = 0;
    final storedNextId = await store.read(CryptoService._otpNextIdPref);
    if (storedNextId != null) {
      nextId = int.tryParse(storedNextId) ?? 0;
    }

    for (var i = 0; i < 10; i++) {
      final keyId = nextId + i;
      final otpPair = await _x25519.newKeyPair();
      final otpPub = await otpPair.extractPublicKey();
      final otpPrivBytes = await (otpPair as SimpleKeyPairData)
          .extractPrivateKeyBytes();

      final pubB64 = base64Encode(otpPub.bytes);
      await store.write(
        '${CryptoService._otpPrivatePrefix}$keyId',
        jsonEncode({'private': base64Encode(otpPrivBytes), 'public': pubB64}),
      );

      otps.add({'key_id': keyId, 'public_key': pubB64});
    }

    // Persist the next counter value for future uploads
    await store.write(CryptoService._otpNextIdPref, '${nextId + 10}');
    debugPrint('[Crypto] Generated OTP keys $nextId..${nextId + 9}');
  }

  /// Check the server's remaining unused OTP count and replenish if low.
  Future<void> checkAndReplenishOtpKeys() async {
    try {
      final response = await http.get(
        Uri.parse('$serverUrl/api/keys/otp-count?device_id=$_deviceId'),
        headers: {'Authorization': 'Bearer $_token'},
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final count = data['count'] as int? ?? 0;
        if (count < 5) {
          debugPrint('[Crypto] OTP count low ($count), replenishing...');
          final otps = <Map<String, dynamic>>[];
          await _generateAndPersistOtpKeys(otps);
          // Upload just the new OTPs (identity bundle already on server)
          await _uploadOtpBatch(otps);
        }
      }
    } catch (e) {
      debugPrint('[Crypto] OTP replenishment check failed: $e');
    }
  }

  /// Upload a batch of OTP public keys to the server.
  Future<void> _uploadOtpBatch(List<Map<String, dynamic>> otps) async {
    if (otps.isEmpty) return;
    if (_identityKeyPair == null) return;

    final publicKey = await _identityKeyPair!.extractPublicKey();
    final spkPub = await _signedPrekeyPair!.extractPublicKey();
    final signature = await _ed25519.sign(
      spkPub.bytes,
      keyPair: _signingKeyPair!,
    );
    final signingPub = await _signingKeyPair!.extractPublicKey();

    final body = jsonEncode({
      'identity_key': base64Encode(publicKey.bytes),
      'signing_key': base64Encode(signingPub.bytes),
      'signed_prekey': base64Encode(spkPub.bytes),
      'signed_prekey_signature': base64Encode(signature.bytes),
      'signed_prekey_id': 1,
      'one_time_prekeys': otps,
      'device_id': _deviceId,
    });

    final response = await http.post(
      Uri.parse('$serverUrl/api/keys/upload'),
      headers: {
        CryptoService._contentTypeHeader: CryptoService._applicationJson,
        'Authorization': 'Bearer $_token',
      },
      body: body,
    );

    if (response.statusCode == 201) {
      debugPrint('[Crypto] Uploaded ${otps.length} new OTP keys');
    }
  }
}
