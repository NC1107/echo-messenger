import 'package:flutter/material.dart';

import 'echo_dropdown.dart';

/// Shared create/rename dialogs for group channels, so the group-info screen
/// and the channel-bar context menu render the same thing. Componentized per
/// the project's "don't paste a widget tree twice" rule — extend these rather
/// than forking a third copy.

/// Result of [showCreateChannelDialog].
typedef CreateChannelResult = ({String name, String kind});

/// Prompt for a new channel's name + kind ('text' or 'voice'). Returns null
/// when cancelled or when the name is empty.
Future<CreateChannelResult?> showCreateChannelDialog(BuildContext context) {
  return showDialog<CreateChannelResult>(
    context: context,
    builder: (_) => const _CreateChannelDialog(),
  );
}

/// Prompt to rename a channel. Returns the new (trimmed) name, or null when
/// cancelled or unchanged/empty.
Future<String?> showRenameChannelDialog(
  BuildContext context, {
  required String currentName,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RenameChannelDialog(currentName: currentName),
  );
}

class _CreateChannelDialog extends StatefulWidget {
  const _CreateChannelDialog();

  @override
  State<_CreateChannelDialog> createState() => _CreateChannelDialogState();
}

class _CreateChannelDialogState extends State<_CreateChannelDialog> {
  final _nameController = TextEditingController();
  String _kind = 'text';

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name: name, kind: _kind));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add channel'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Channel name',
              hintText: 'e.g. general',
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          EchoDropdown<String>(
            value: _kind,
            labelText: 'Type',
            items: const [
              DropdownMenuItem(value: 'text', child: Text('Text')),
              DropdownMenuItem(value: 'voice', child: Text('Voice')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _kind = v);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _RenameChannelDialog extends StatefulWidget {
  const _RenameChannelDialog({required this.currentName});

  final String currentName;

  @override
  State<_RenameChannelDialog> createState() => _RenameChannelDialogState();
}

class _RenameChannelDialogState extends State<_RenameChannelDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentName.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final next = _controller.text.trim();
    if (next.isEmpty || next == widget.currentName) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, next);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename channel'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Channel name'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Rename')),
      ],
    );
  }
}
