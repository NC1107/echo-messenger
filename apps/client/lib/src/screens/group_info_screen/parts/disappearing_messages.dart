// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Disappearing-messages TTL options shown in the picker.
const _kTtlOptions = [
  (label: 'Off', seconds: null),
  (label: '30 seconds', seconds: 30),
  (label: '5 minutes', seconds: 300),
  (label: '1 hour', seconds: 3600),
  (label: '1 day', seconds: 86400),
  (label: '1 week', seconds: 604800),
];

/// TTL picker + persistence for the disappearing-messages feature.
extension _DisappearingMessages on _GroupInfoScreenState {
  String _ttlLabel(int? seconds) {
    for (final opt in _kTtlOptions) {
      if (opt.seconds == seconds) return opt.label;
    }
    return '$seconds seconds';
  }

  Future<void> _setDisappearingTtl(int? seconds) async {
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.put(
              Uri.parse(
                '$serverUrl/api/conversations/${widget.conversationId}/disappearing',
              ),
              headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
              body: jsonEncode({'ttl_seconds': seconds}),
            ),
          );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() => _disappearingTtl = seconds);
        ToastService.show(
          context,
          seconds == null
              ? 'Disappearing messages turned off'
              : 'Messages disappear after ${_ttlLabel(seconds)}',
          type: ToastType.success,
        );
      } else {
        ToastService.show(
          context,
          'Failed to update disappearing messages',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[GroupInfo] _setDisappearingTtl failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to update disappearing messages',
          type: ToastType.error,
        );
      }
    }
  }

  Widget _buildDisappearingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Disappearing Messages',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Auto-delete after'),
          trailing: DropdownButton<int?>(
            value: _disappearingTtl,
            underline: const SizedBox.shrink(),
            items: _kTtlOptions.map((opt) {
              return DropdownMenuItem<int?>(
                value: opt.seconds,
                child: Text(opt.label),
              );
            }).toList(),
            onChanged: (v) => _setDisappearingTtl(v),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}
