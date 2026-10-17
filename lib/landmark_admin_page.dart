import 'package:flutter/material.dart';

import 'domain.dart';
import 'storage.dart';
import 'supporting_photos_view.dart';

class LandmarkAdminPage extends StatefulWidget {
  const LandmarkAdminPage({
    super.key,
    required this.project,
    required this.store,
    required this.floor,
    required this.onExport,
  });
  final MapperProject project;
  final ProjectStore store;
  final String floor;
  final Future<void> Function() onExport;
  @override
  State<LandmarkAdminPage> createState() => _LandmarkAdminPageState();
}

class _LandmarkAdminPageState extends State<LandmarkAdminPage> {
  late String floor = widget.floor;
  bool busy = false;
  String? error;
  Future<void> export() async {
    setState(() => busy = true);
    try {
      await widget.onExport();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> open(PanoramaLabel label) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SupportingPhotosView(
          label: label,
          file: (photo) => widget.store.photoOriginal(widget.project, photo),
          onAdd: (bytes) =>
              widget.store.addSupportingPhoto(widget.project, label, bytes),
          onRemove: (photo) async {
            final index = label.photos.indexOf(photo);
            label.photos.remove(photo);
            try {
              await widget.store.save(widget.project);
            } catch (_) {
              label.photos.insert(index, photo);
              rethrow;
            }
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final landmarks = [
      for (final centre in widget.project.centres.where(
        (c) => c.floor == floor,
      ))
        for (final panorama in centre.panoramas)
          for (final label in panorama.labels) (label: label, centre: centre),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin · landmark photos'),
        actions: [
          TextButton.icon(
            onPressed: busy ? null : export,
            icon: const Icon(Icons.ios_share),
            label: const Text('Export mapper'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Select an existing landmark label, then take a photo or choose pictures from this phone. Changes save into this local mapper project. Export the updated .mapper file to transfer them.',
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: floor,
                  decoration: const InputDecoration(labelText: 'Floor'),
                  items: widget.project.floors
                      .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                      .toList(),
                  onChanged: busy
                      ? null
                      : (value) {
                          if (value != null) setState(() => floor = value);
                        },
                ),
                if (error != null) SelectableText(error!),
              ],
            ),
          ),
          if (landmarks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No landmark labels on this floor. Prepare the map and panorama labels on Windows, then import that project here.',
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: landmarks.length,
              itemBuilder: (context, index) {
                final entry = landmarks[index];
                return Card(
                  child: ListTile(
                    title: Text(entry.label.name),
                    subtitle: Text(
                      '${entry.centre.name} · ${entry.label.photos.length} supporting photos',
                    ),
                    leading: const Icon(Icons.place_outlined),
                    trailing: const Icon(Icons.add_a_photo_outlined),
                    onTap: busy ? null : () => open(entry.label),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
