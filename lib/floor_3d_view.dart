import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'domain.dart';
import 'map_view.dart';

/// A metric, orthographic orbit view of the current floor's annotations.
/// Heights and base offsets come from GeoJSON properties, in metres.
extension Feature3DHeights on MapFeature {
  static double _metres(dynamic value) {
    final parsed = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value.trim())
        : null;
    return parsed != null && parsed.isFinite && parsed >= 0 ? parsed : 0;
  }

  double get baseHeightMetres => _metres(properties['baseHeight']);
  double get heightMetres => _metres(properties['height']);
  double get topHeightMetres => baseHeightMetres + heightMetres;
}

class Floor3DView extends StatefulWidget {
  const Floor3DView({
    super.key,
    required this.features,
    required this.centres,
    required this.selectedFeature,
    required this.selectedCentre,
    required this.onSelect,
  });

  final List<MapFeature> features;
  final List<CaptureCentre> centres;
  final String? selectedFeature, selectedCentre;
  final void Function(String? centreId, String? featureId) onSelect;

  @override
  State<Floor3DView> createState() => _Floor3DViewState();
}

class _Floor3DViewState extends State<Floor3DView> {
  double yaw = -.45, tilt = .85, zoom = 1;
  double startZoom = 1;
  Offset pan = Offset.zero;

  void reset() => setState(() {
    yaw = -.45;
    tilt = .85;
    zoom = 1;
    pan = Offset.zero;
  });

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Material(
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              const Text('Drag to rotate · scroll/pinch to zoom'),
              IconButton(
                tooltip: 'Zoom out',
                onPressed: () =>
                    setState(() => zoom = (zoom / 1.25).clamp(.25, 8)),
                icon: const Icon(Icons.zoom_out),
              ),
              IconButton(
                tooltip: 'Zoom in',
                onPressed: () =>
                    setState(() => zoom = (zoom * 1.25).clamp(.25, 8)),
                icon: const Icon(Icons.zoom_in),
              ),
              TextButton.icon(
                onPressed: reset,
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('Reset view'),
              ),
              const Text('GeoJSON heights · metres'),
            ],
          ),
        ),
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            final projection = Floor3DProjection(
              widget.features,
              widget.centres,
              size,
              yaw: yaw,
              tilt: tilt,
              zoom: zoom,
              pan: pan,
            );
            final painter = Floor3DPainter(
              projection,
              widget.features,
              widget.centres,
              selectedFeature: widget.selectedFeature,
              selectedCentre: widget.selectedCentre,
            );
            return ClipRect(
              child: Listener(
                onPointerSignal: (event) {
                  if (event is PointerScrollEvent) {
                    setState(
                      () =>
                          zoom = (zoom * math.exp(-event.scrollDelta.dy * .002))
                              .clamp(.25, 8),
                    );
                  }
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (_) => startZoom = zoom,
                  onScaleUpdate: (event) => setState(() {
                    if (event.pointerCount > 1) {
                      zoom = (startZoom * event.scale).clamp(.25, 8);
                      pan += event.focalPointDelta;
                    } else {
                      yaw += event.focalPointDelta.dx * .008;
                      tilt = (tilt + event.focalPointDelta.dy * .006).clamp(
                        .2,
                        1.4,
                      );
                    }
                  }),
                  onTapUp: (event) {
                    final tap = event.localPosition;
                    for (final c in widget.centres.reversed) {
                      if ((projection.screen(c.position, .15) - tap).distance <
                          16) {
                        widget.onSelect(c.id, null);
                        return;
                      }
                    }
                    for (final f in widget.features.reversed.where(
                      (f) => f.isPoint,
                    )) {
                      if ((projection.screen(
                                    f.rings.first.first,
                                    f.topHeightMetres,
                                  ) -
                                  tap)
                              .distance <
                          16) {
                        widget.onSelect(null, f.id);
                        return;
                      }
                    }
                    for (final f in widget.features.reversed.where(
                      (f) => f.type == 'LineString',
                    )) {
                      if (painter.hitsLine(f, tap)) {
                        widget.onSelect(null, f.id);
                        return;
                      }
                    }
                    for (final f in painter.polygons.reversed) {
                      if (painter.shape(f, f.topHeightMetres).contains(tap) ||
                          painter.walls(f).any((wall) => wall.contains(tap))) {
                        widget.onSelect(null, f.id);
                        return;
                      }
                    }
                    widget.onSelect(null, null);
                  },
                  child: CustomPaint(size: size, painter: painter),
                ),
              ),
            );
          },
        ),
      ),
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'GeoJSON height + baseHeight · missing or invalid values use 0 m · select to inspect · edit geometry in 2D',
        ),
      ),
    ],
  );
}

class Floor3DProjection {
  Floor3DProjection(
    List<MapFeature> features,
    List<CaptureCentre> centres,
    Size size, {
    required this.yaw,
    required this.tilt,
    required double zoom,
    required Offset pan,
  }) : base = MapTransform(features, centres, size) {
    final extents = <Offset>[
      for (final f in features)
        for (final p in f.points) ...[
          projected(p, f.baseHeightMetres),
          projected(p, f.topHeightMetres),
        ],
      for (final c in centres) projected(c.position, .15),
    ];
    final bounds = extents.isEmpty
        ? const Rect.fromLTWH(-2.5, -2.5, 5, 5)
        : Rect.fromLTRB(
            extents.map((p) => p.dx).reduce(math.min),
            extents.map((p) => p.dy).reduce(math.min),
            extents.map((p) => p.dx).reduce(math.max),
            extents.map((p) => p.dy).reduce(math.max),
          );
    scale =
        math.min(
          math.max(1, size.width - 90) / math.max(5, bounds.width),
          math.max(1, size.height - 90) / math.max(5, bounds.height),
        ) *
        .8 *
        zoom;
    origin = size.center(Offset.zero) - bounds.center * scale + pan;
  }
  final MapTransform base;
  final double yaw, tilt;
  late final double scale;
  late final Offset origin;

  XY rotated(GeoPoint point) {
    final p = base.frame.project(point);
    final x = p.x - base.cx, y = p.y - base.cy;
    return XY(
      x * math.cos(yaw) - y * math.sin(yaw),
      x * math.sin(yaw) + y * math.cos(yaw),
    );
  }

  double depth(GeoPoint point) => rotated(point).y;
  Offset projected(GeoPoint point, double height) {
    final p = rotated(point);
    return Offset(p.x, -p.y * math.sin(tilt) - height * math.cos(tilt));
  }

  Offset screen(GeoPoint point, [double height = 0]) =>
      origin + projected(point, height) * scale;
}

class Floor3DPainter extends CustomPainter {
  Floor3DPainter(
    this.t,
    this.features,
    this.centres, {
    this.selectedFeature,
    this.selectedCentre,
  });
  final Floor3DProjection t;
  final List<MapFeature> features;
  final List<CaptureCentre> centres;
  final String? selectedFeature, selectedCentre;

  List<MapFeature> get polygons =>
      features.where((f) => f.type == 'Polygon').toList()..sort((a, b) {
        if (a.isBoundary != b.isBoundary) return a.isBoundary ? -1 : 1;
        double depth(MapFeature f) =>
            f.points.map(t.depth).reduce((a, b) => a + b) / f.points.length;
        return depth(b).compareTo(depth(a));
      });

  Path shape(MapFeature feature, double height) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final ring in feature.rings) {
      path.addPolygon(
        ring.map((p) => t.screen(p, height)).toList(),
        feature.type == 'Polygon',
      );
    }
    return path;
  }

  Iterable<Path> walls(MapFeature f) sync* {
    if (f.heightMetres == 0) return;
    for (final ring in f.rings) {
      for (var i = 1; i < ring.length; i++) {
        yield Path()..addPolygon([
          t.screen(ring[i - 1], f.baseHeightMetres),
          t.screen(ring[i], f.baseHeightMetres),
          t.screen(ring[i], f.topHeightMetres),
          t.screen(ring[i - 1], f.topHeightMetres),
        ], true);
      }
    }
  }

  bool hitsLine(MapFeature f, Offset tap) {
    final ring = f.rings.single;
    for (var i = 1; i < ring.length; i++) {
      final a = t.screen(ring[i - 1], f.topHeightMetres),
          b = t.screen(ring[i], f.topHeightMetres);
      final delta = b - a;
      final length = delta.distanceSquared;
      if (length == 0) continue;
      final q = tap - a;
      final fraction = ((q.dx * delta.dx + q.dy * delta.dy) / length).clamp(
        0.0,
        1.0,
      );
      if ((tap - (a + delta * fraction)).distance < 10) return true;
    }
    return false;
  }

  void label(Canvas canvas, String text, Offset point) {
    final p = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(
          color: Color(0xff20344a),
          fontSize: 12,
          backgroundColor: Color(0xdfffffff),
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 140);
    p.paint(canvas, point);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xffedf3fa),
    );
    for (final f in polygons) {
      final selected = f.id == selectedFeature;
      var color = f.isBoundary
          ? const Color(0xffdce4ee)
          : const Color(0xff8fc8bc);
      final fill = f.properties['fillColor'];
      if (fill is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(fill)) {
        color = Color(int.parse('ff${fill.substring(1)}', radix: 16));
      }
      if (selected) color = Colors.orange.shade300;
      for (final wall in walls(f)) {
        canvas.drawPath(
          wall,
          Paint()..color = Color.lerp(color, Colors.black, .2)!,
        );
        canvas.drawPath(
          wall,
          Paint()
            ..color = Colors.blueGrey
            ..style = PaintingStyle.stroke,
        );
      }
      final top = shape(f, f.topHeightMetres);
      canvas.drawPath(top, Paint()..color = color.withValues(alpha: .65));
      canvas.drawPath(
        top,
        Paint()
          ..color = selected ? Colors.deepOrange : Colors.blueGrey
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 3 : 1,
      );
    }
    for (final f in features.where((f) => f.type == 'LineString')) {
      canvas.drawPath(
        shape(f, f.topHeightMetres),
        Paint()
          ..color = f.id == selectedFeature
              ? Colors.deepOrange
              : f.properties['reviewed'] == true
              ? Colors.indigo
              : Colors.grey
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4,
      );
    }
    for (final f in features.where((f) => !f.isBoundary)) {
      if (f.isPoint) {
        final p = t.screen(f.rings.first.first, f.topHeightMetres);
        canvas.drawCircle(
          p,
          f.id == selectedFeature ? 8 : 5,
          Paint()
            ..color = f.id == selectedFeature ? Colors.deepOrange : Colors.teal,
        );
      }
      final height = f.topHeightMetres;
      label(
        canvas,
        f.name,
        shape(f, height).getBounds().center + const Offset(6, -16),
      );
    }
    for (final c in centres) {
      final p = t.screen(c.position, .15);
      canvas.drawCircle(
        p,
        c.id == selectedCentre ? 12 : 9,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        p,
        c.id == selectedCentre ? 9 : 6,
        Paint()..color = c.panoramas.isEmpty ? Colors.deepOrange : Colors.blue,
      );
      label(canvas, c.name, p + const Offset(12, 4));
    }
    // Compass follows camera rotation.
    final north = Offset(-math.sin(t.yaw), -math.cos(t.yaw) * math.sin(t.tilt));
    final start = Offset(35, size.height - 40);
    canvas.drawLine(
      start,
      start + north * 24,
      Paint()
        ..color = Colors.blueGrey
        ..strokeWidth = 3,
    );
    label(canvas, 'N', start + north * 32 - const Offset(4, 6));
    if (features.isEmpty && centres.isEmpty) {
      label(canvas, 'No annotations on this floor', size.center(Offset.zero));
    }
  }

  @override
  bool shouldRepaint(covariant Floor3DPainter oldDelegate) => true;
}
