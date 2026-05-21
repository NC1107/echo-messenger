part of '../../notification_section.dart';

// ---------------------------------------------------------------------------
// Sound picker row
// ---------------------------------------------------------------------------

class _SoundPickerRow extends StatelessWidget {
  const _SoundPickerRow({required this.selected, required this.onChanged});

  final NotificationSound selected;
  final ValueChanged<NotificationSound> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Message Sound',
                  style: TextStyle(color: context.textPrimary, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sound played when you receive a message.',
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _SoundDropdown(selected: selected, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SoundDropdown extends StatelessWidget {
  const _SoundDropdown({required this.selected, required this.onChanged});

  final NotificationSound selected;
  final ValueChanged<NotificationSound> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<NotificationSound>(
            value: selected,
            dropdownColor: Theme.of(context).colorScheme.surface,
            style: TextStyle(color: context.textPrimary, fontSize: 13),
            icon: Icon(Icons.expand_more, size: 18, color: context.textMuted),
            borderRadius: BorderRadius.circular(8),
            items: NotificationSound.values.map((sound) {
              return DropdownMenuItem(
                value: sound,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      sound == NotificationSound.none
                          ? Icons.volume_off_outlined
                          : Icons.volume_up_outlined,
                      size: 15,
                      color: context.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(sound.label),
                  ],
                ),
              );
            }).toList(),
            onChanged: (sound) {
              if (sound != null) onChanged(sound);
            },
          ),
        ),
      ),
    );
  }
}
