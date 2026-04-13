import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/crypto_provider.dart';
import '../theme/echo_theme.dart';

/// Displays a persistent amber banner when the Signal Protocol crypto layer
/// failed to initialize (e.g. keyring unavailable on Linux). Offers a Retry
/// button so the user can re-attempt initialization without restarting.
class CryptoDegradedBanner extends ConsumerWidget {
  const CryptoDegradedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cryptoState = ref.watch(cryptoProvider);
    final visible = !cryptoState.isInitialized && cryptoState.error != null;

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      child: visible
          ? Semantics(
              label: 'encryption unavailable warning',
              child: Container(
                width: double.infinity,
                color: EchoTheme.warning.withValues(alpha: 0.15),
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.lock_open_outlined,
                      size: 12,
                      color: EchoTheme.warning,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        cryptoState.error!,
                        style: TextStyle(
                          fontSize: 12,
                          color: EchoTheme.warning,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Semantics(
                      label: 'retry encryption',
                      button: true,
                      child: GestureDetector(
                        onTap: () => ref
                            .read(cryptoProvider.notifier)
                            .initAndUploadKeys(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: EchoTheme.warning.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: EchoTheme.warning,
                              width: 1,
                            ),
                          ),
                          child: Text(
                            'Retry',
                            style: TextStyle(
                              fontSize: 11,
                              color: EchoTheme.warning,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
