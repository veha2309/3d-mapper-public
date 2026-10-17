import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'domain.dart';

class SupportingPhotosView extends StatefulWidget {
  const SupportingPhotosView({
    super.key,
    required this.label,
    required this.file,
    this.onAdd,
    this.onRemove,
  });
  final PanoramaLabel label;
  final File Function(LandmarkPhoto) file;
  final Future<void> Function(Uint8List)? onAdd;
  final Future<void> Function(LandmarkPhoto)? onRemove;
  @override
  State<SupportingPhotosView> createState() => _SupportingPhotosViewState();
}

class _SupportingPhotosViewState extends State<SupportingPhotosView> {
  bool busy = false;
  String? status;
  Future<void> add() async {
    setState(() => busy = true);
    var added = 0;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
        allowMultiple: true,
      );
      if (result == null) return;
      for (final picked in result.files) {
        if (picked.size > 32 * 1024 * 1024) {
          throw const FormatException(
            'Each landmark photo must be smaller than 32 MiB',
          );
        }
        await widget.onAdd!(
          picked.bytes ?? await File(picked.path!).readAsBytes(),
        );
        added++;
        if (mounted) setState(() => status = 'Added $added supporting photos');
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Added $added photos. $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> takePhoto() async {
    const channel = MethodChannel('three_d_mapper/recognition');
    setState(() => busy = true);
    String? capturePath;
    try {
      final allowed =
          await channel.invokeMethod<bool>('requestPermission') ?? false;
      if (!allowed) {
        throw const FormatException(
          'Camera permission is required to take a landmark photo',
        );
      }
      capturePath = await channel.invokeMethod<String>('captureLandmarkPhoto');
      if (capturePath == null) return;
      final file = File(capturePath);
      if (await file.length() > 32 * 1024 * 1024) {
        throw const FormatException('Captured photo exceeds 32 MiB');
      }
      await widget.onAdd!(await file.readAsBytes());
      if (mounted) {
        setState(
          () => status = 'Photo added to this landmark. Export the updated mapper file when ready.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not add camera photo: $e');
    } finally {
      if (capturePath != null) {
        try {
          await channel.invokeMethod<void>('discardLandmarkCapture', {
            'path': capturePath,
          });
        } catch (_) {}
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> remove(LandmarkPhoto photo) async {
    setState(() => busy = true);
    try {
      await widget.onRemove!(photo);
      if (mounted) setState(() => status = 'Supporting photo removed');
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(
        title: Text('Supporting photos · ${widget.label.name}'),
        actions: [
          if (widget.onAdd != null && Platform.isAndroid)
            TextButton.icon(
              onPressed: busy ? null : takePhoto,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Take photo'),
            ),
          if (widget.onAdd != null)
            TextButton.icon(
              onPressed: busy ? null : add,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add photos'),
            ),
        ],
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Add separate JPG/PNG photos of this same landmark from useful angles and distances. Keep the landmark near the centre. Each photo is another reference view, not an extra confidence vote.',
            ),
          ),
          if (status != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(status!),
            ),
          Expanded(
            child: widget.label.photos.isEmpty
                ? const Center(
                    child: Text(
                      'No supporting photos yet. The panorama reference is still used.',
                    ),
                  )
                : ListView.builder(
                    itemCount: widget.label.photos.length,
                    itemBuilder: (context, index) {
                      final photo = widget.label.photos[index];
                      return Card(
                        child: Column(
                          children: [
                            Image.file(
                              widget.file(photo),
                              height: 220,
                              width: double.infinity,
                              fit: BoxFit.contain,
                              cacheWidth: 800,
                              errorBuilder: (_, error, stack) =>
                                  Text('Photo unavailable: $error'),
                            ),
                            ListTile(
                              title: Text('Supporting view ${index + 1}'),
                              subtitle: Text(photo.id),
                              trailing: widget.onRemove == null
                                  ? null
                                  : IconButton(
                                      tooltip: 'Remove supporting photo',
                                      onPressed: busy
                                          ? null
                                          : () => remove(photo),
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
