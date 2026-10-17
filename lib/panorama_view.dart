import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'reference_renderer.dart';
import 'label_dialog.dart';
import 'supporting_photos_view.dart';

import 'domain.dart';
import 'panorama_geometry.dart';

class PanoramaView extends StatefulWidget {
  const PanoramaView({
    super.key,
    required this.file,
    required this.heading,
    this.panorama,
    this.landmarks = const [],
    this.onAddLabel,
    this.onEditLabel,
    this.onAddPhoto,
    this.onRemovePhoto,
    this.supportingPhotoFile,
  });
  final File file;
  final double heading;
  final Panorama? panorama;
  final List<MapFeature> landmarks;
  final Future<void> Function(
    String name,
    ViewDirection direction,
    Uint8List reference,
    String? featureId,
  )?
  onAddLabel;
  final Future<void> Function(PanoramaLabel label, String? name)? onEditLabel;
  final Future<void> Function(PanoramaLabel label, Uint8List bytes)? onAddPhoto;
  final Future<void> Function(PanoramaLabel label, LandmarkPhoto photo)?
  onRemovePhoto;
  final File Function(LandmarkPhoto photo)? supportingPhotoFile;
  @override
  State<PanoramaView> createState() => _PanoramaViewState();
}

class _PanoramaViewState extends State<PanoramaView> {
  ui.FragmentProgram? program;
  ui.FragmentShader? shader;
  ui.Image? image;
  String? error;
  double yaw = 0, pitch = 0, fov = 80, startFov = 80;
  bool adding = false, saving = false;
  List<PanoramaLabel> get labels => widget.panorama?.labels ?? [];
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    ui.FragmentShader? loadedShader;
    ui.Image? loadedImage;
    try {
      final loadedProgram = await ui.FragmentProgram.fromAsset(
        'shaders/panorama.frag',
      );
      loadedShader = loadedProgram.fragmentShader();
      final buffer = await ui.ImmutableBuffer.fromFilePath(widget.file.path);
      ui.ImageDescriptor? descriptor;
      ui.Codec? codec;
      try {
        descriptor = await ui.ImageDescriptor.encoded(buffer);
        codec = await descriptor.instantiateCodec(
          targetWidth: math.min(4096, descriptor.width),
        );
        loadedImage = (await codec.getNextFrame()).image;
      } finally {
        codec?.dispose();
        descriptor?.dispose();
        buffer.dispose();
      }
      if (!mounted) {
        loadedShader.dispose();
        loadedImage.dispose();
        return;
      }
      setState(() {
        program = loadedProgram;
        shader = loadedShader;
        image = loadedImage;
      });
    } catch (e) {
      loadedShader?.dispose();
      loadedImage?.dispose();
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<Uint8List> referenceImage(ViewDirection direction) async {
    final rgba = await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) throw StateError('Could not read panorama pixels');
    return compute(renderPerspectivePng, {
      'pixels': rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes),
      'width': image!.width,
      'height': image!.height,
      'yaw': direction.yaw,
      'pitch': direction.pitch,
    });
  }

  Future<void> labelAt(Offset point, Size size) async {
    if (saving || widget.onAddLabel == null) return;
    setState(() {
      saving = true;
      adding = false;
    });
    final direction = directionAt(point, size, yaw, pitch, fov);
    try {
      final bytes = await referenceImage(direction);
      if (!mounted) return;
      final entry = await showDialog<LabelEntry>(
        context: context,
        builder: (_) =>
            LabelDialog(preview: bytes, landmarks: widget.landmarks),
      );
      if (entry != null) {
        await widget.onAddLabel!(entry.name, direction, bytes, entry.featureId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Label saved. Export the updated project for Android testing.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not save label: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> manageLabels() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .65,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Landmark labels',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (labels.isEmpty)
                  const Text(
                    'No labels yet. On Windows choose Add label, then click a landmark.',
                  ),
                for (final label in labels)
                  Card(
                    child: Column(
                      children: [
                        ListTile(
                          title: Text(label.name),
                          subtitle: Text(
                            '${label.photos.length} separate supporting photos',
                          ),
                          onTap: () {
                            setState(() {
                              yaw = label.yaw;
                              pitch = label.pitch;
                            });
                            Navigator.pop(sheetContext);
                          },
                        ),
                        Wrap(
                          children: [
                            if (widget.supportingPhotoFile != null)
                              TextButton.icon(
                                icon: const Icon(Icons.photo_library_outlined),
                                label: Text(
                                  widget.onAddPhoto == null
                                      ? 'View photos'
                                      : 'Supporting photos',
                                ),
                                onPressed: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => SupportingPhotosView(
                                        label: label,
                                        file: widget.supportingPhotoFile!,
                                        onAdd: widget.onAddPhoto == null
                                            ? null
                                            : (bytes) => widget.onAddPhoto!(
                                                label,
                                                bytes,
                                              ),
                                        onRemove: widget.onRemovePhoto == null
                                            ? null
                                            : (photo) => widget.onRemovePhoto!(
                                                label,
                                                photo,
                                              ),
                                      ),
                                    ),
                                  );
                                  if (mounted) setState(() {});
                                  if (context.mounted) setSheet(() {});
                                },
                              ),
                            if (widget.onEditLabel != null)
                              TextButton.icon(
                                icon: const Icon(Icons.edit),
                                label: const Text('Edit label'),
                                onPressed: () async {
                                  final entry = await showDialog<LabelEntry>(
                                    context: context,
                                    builder: (_) => LabelDialog(
                                      initialName: label.name,
                                      allowRemove: true,
                                    ),
                                  );
                                  if (entry == null) return;
                                  try {
                                    await widget.onEditLabel!(
                                      label,
                                      entry.remove ? null : entry.name,
                                    );
                                    if (mounted) setState(() {});
                                    if (context.mounted) setSheet(() {});
                                  } catch (e) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            SnackBar(content: Text('$e')),
                                          );
                                    }
                                  }
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    shader?.dispose();
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('360° panorama'),
        actions: [
          if (widget.onAddLabel != null)
            TextButton.icon(
              onPressed: saving || image == null
                  ? null
                  : () => setState(() => adding = !adding),
              icon: Icon(adding ? Icons.close : Icons.add_location_alt),
              label: Text(adding ? 'Cancel' : 'Add label'),
            ),
          TextButton.icon(
            onPressed: saving ? null : manageLabels,
            icon: const Icon(Icons.label_outline),
            label: Text('Labels (${labels.length})'),
          ),
          IconButton(
            tooltip: 'Reset view',
            onPressed: () => setState(() {
              yaw = 0;
              pitch = 0;
              fov = 80;
            }),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: error != null
          ? Center(child: SelectableText('Unable to display panorama: $error'))
          : image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (saving) const LinearProgressIndicator(),
                if (adding)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Click the landmark to label it. Its surrounding view becomes a recognition reference.',
                    ),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final size = constraints.biggest;
                      return AbsorbPointer(
                        absorbing: saving,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: adding
                              ? (details) =>
                                    labelAt(details.localPosition, size)
                              : null,
                          onScaleStart: (_) => startFov = fov,
                          onScaleUpdate: (details) => setState(() {
                            yaw -= details.focalPointDelta.dx * .006;
                            pitch = (pitch + details.focalPointDelta.dy * .006)
                                .clamp(-1.45, 1.45);
                            if (details.pointerCount > 1) {
                              fov = (startFov / details.scale).clamp(35, 110);
                            }
                          }),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CustomPaint(
                                key: const ValueKey('panorama-canvas'),
                                painter: _SpherePainter(
                                  shader!,
                                  image!,
                                  yaw,
                                  pitch,
                                  fov,
                                ),
                              ),
                              for (final label in labels)
                                if (screenDirection(
                                      ViewDirection(label.yaw, label.pitch),
                                      size,
                                      yaw,
                                      pitch,
                                      fov,
                                    )
                                    case final Offset location)
                                  Positioned(
                                    left: location.dx - 8,
                                    top: location.dy - 8,
                                    child: IgnorePointer(
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.location_on,
                                            color: Colors.amber,
                                            size: 22,
                                          ),
                                          Container(
                                            color: Colors.black87,
                                            padding: const EdgeInsets.all(4),
                                            constraints: const BoxConstraints(
                                              maxWidth: 180,
                                            ),
                                            child: Text(
                                              label.name,
                                              style: const TextStyle(
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      tooltip: 'Look left',
                      onPressed: () => setState(() => yaw -= math.pi / 6),
                      icon: const Icon(Icons.rotate_left),
                    ),
                    Text(
                      'Bearing ${((yaw * 180 / math.pi + widget.heading) % 360).round()}° · heading offset ${widget.heading.round()}°',
                    ),
                    IconButton(
                      tooltip: 'Look right',
                      onPressed: () => setState(() => yaw += math.pi / 6),
                      icon: const Icon(Icons.rotate_right),
                    ),
                    IconButton(
                      tooltip: 'Look up',
                      onPressed: () => setState(
                        () => pitch = (pitch + .2).clamp(-1.45, 1.45),
                      ),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    IconButton(
                      tooltip: 'Look down',
                      onPressed: () => setState(
                        () => pitch = (pitch - .2).clamp(-1.45, 1.45),
                      ),
                      icon: const Icon(Icons.arrow_downward),
                    ),
                    IconButton(
                      tooltip: 'Zoom in',
                      onPressed: () =>
                          setState(() => fov = (fov - 10).clamp(35, 110)),
                      icon: const Icon(Icons.zoom_in),
                    ),
                    IconButton(
                      tooltip: 'Zoom out',
                      onPressed: () =>
                          setState(() => fov = (fov + 10).clamp(35, 110)),
                      icon: const Icon(Icons.zoom_out),
                    ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text(
                    'Preview ≤4096 px. Labels identify visible landmarks; they do not measure depth.',
                  ),
                ),
              ],
            ),
    ),
  );
}

class _SpherePainter extends CustomPainter {
  _SpherePainter(this.shader, this.image, this.yaw, this.pitch, this.fov);
  final ui.FragmentShader shader;
  final ui.Image image;
  final double yaw, pitch, fov;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, image.width.toDouble())
      ..setFloat(3, image.height.toDouble())
      ..setFloat(4, yaw)
      ..setFloat(5, pitch)
      ..setFloat(6, fov * math.pi / 180)
      ..setImageSampler(0, image);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_SpherePainter old) => true;
}
