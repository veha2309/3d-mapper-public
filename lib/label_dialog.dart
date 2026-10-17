import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'domain.dart';

class LabelEntry {
  const LabelEntry(this.name, this.featureId, {this.remove = false});
  final String name;
  final String? featureId;
  final bool remove;
}

class LabelDialog extends StatefulWidget {
  const LabelDialog({
    super.key,
    this.preview,
    this.landmarks = const [],
    this.initialName = '',
    this.allowRemove = false,
  });
  final Uint8List? preview;
  final List<MapFeature> landmarks;
  final String initialName;
  final bool allowRemove;
  @override
  State<LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<LabelDialog> {
  late final TextEditingController name = TextEditingController(
    text: widget.initialName,
  );
  String? featureId, error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void save() {
    if (name.text.trim().isEmpty) {
      setState(() => error = 'Enter a name');
      return;
    }
    Navigator.pop(context, LabelEntry(name.text.trim(), featureId));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.allowRemove ? 'Edit label' : 'Label this landmark'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.preview != null) ...[
              Image.memory(widget.preview!, height: 180, fit: BoxFit.contain),
              const Text(
                'This perspective view will be matched against the Android camera. Include distinctive surrounding details.',
              ),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: name,
              autofocus: true,
              maxLength: 160,
              onSubmitted: (_) => save(),
              decoration: InputDecoration(
                labelText: 'Place or landmark name',
                errorText: error,
              ),
            ),
            if (widget.preview != null) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: '',
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Link to map landmark (optional)',
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('No map link')),
                  ...widget.landmarks.map(
                    (f) => DropdownMenuItem(
                      value: f.id,
                      child: Text(f.name, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ],
                onChanged: (id) =>
                    setState(() => featureId = id == '' ? null : id),
              ),
            ],
          ],
        ),
      ),
    ),
    actions: [
      if (widget.allowRemove)
        TextButton(
          onPressed: () =>
              Navigator.pop(context, const LabelEntry('', null, remove: true)),
          child: const Text('Remove label'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: save,
        child: Text(widget.allowRemove ? 'Save' : 'Save label'),
      ),
    ],
  );
}
