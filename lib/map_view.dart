import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'domain.dart';
import 'route_drawing.dart';

class FloorMap extends StatelessWidget {
  const FloorMap({
    super.key,
    required this.features,
    required this.centres,
    required this.preview,
    required this.spacing,
    required this.draft,
    required this.selectedCentre,
    required this.selectedFeature,
    required this.onTap,
  });
  final List<MapFeature> features;
  final List<CaptureCentre> centres;
  final List<GeoPoint> preview, draft;
  final double spacing;
  final String? selectedCentre, selectedFeature;
  final void Function(GeoPoint point, String? centreId, String? featureId)
  onTap;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      final transform = MapTransform(features, centres, size);
      return ClipRect(
        child: InteractiveViewer(
          minScale: .5,
          maxScale: 12,
          boundaryMargin: const EdgeInsets.all(300),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (event) {
              final tap = event.localPosition;
              String? centreId, featureId;
              var best = 18.0;
              for (final c in centres) {
                final distance = (transform.screen(c.position) - tap).distance;
                if (distance < best) {
                  best = distance;
                  centreId = c.id;
                }
              }
              for (final f in features.reversed) {
                if (f.isPoint
                    ? (transform.screen(f.rings.first.first) - tap).distance <
                          14
                    : f.type == 'LineString'
                    ? transform.hitsLine(f, tap)
                    : transform.shape(f).contains(tap)) {
                  featureId = f.id;
                  break;
                }
              }
              onTap(transform.geo(tap), centreId, featureId);
            },
            child: SizedBox.fromSize(
              size: size,
              child: CustomPaint(
                painter: FloorPainter(
                  transform,
                  features,
                  centres,
                  preview,
                  spacing,
                  draft,
                  selectedCentre,
                  selectedFeature,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class MapTransform {
  MapTransform(
    List<MapFeature> features,
    List<CaptureCentre> centres,
    Size size,
  ) {
    final points = [
      ...features.expand((f) => f.points),
      ...centres.map((c) => c.position),
    ];
    frame = LocalFrame(points.isEmpty ? const GeoPoint(0, 0) : points.first);
    final xy = points.map(frame.project).toList();
    final minX = xy.isEmpty ? 0.0 : xy.map((p) => p.x).reduce(math.min);
    final minY = xy.isEmpty ? 0.0 : xy.map((p) => p.y).reduce(math.min);
    final maxX = xy.isEmpty ? 10.0 : xy.map((p) => p.x).reduce(math.max);
    final maxY = xy.isEmpty ? 10.0 : xy.map((p) => p.y).reduce(math.max);
    scale = math.min(
      math.max(1, size.width - 90) / math.max(5, maxX - minX),
      math.max(1, size.height - 90) / math.max(5, maxY - minY),
    );
    cx = (minX + maxX) / 2;
    cy = (minY + maxY) / 2;
    centre = Offset(size.width / 2, size.height / 2);
  }
  late final LocalFrame frame;
  late final double scale, cx, cy;
  late final Offset centre;
  Offset screen(GeoPoint p) {
    final xy = frame.project(p);
    return centre + Offset((xy.x - cx) * scale, -(xy.y - cy) * scale);
  }

  GeoPoint geo(Offset p) => frame.unproject(
    XY((p.dx - centre.dx) / scale + cx, -(p.dy - centre.dy) / scale + cy),
  );
  bool hitsLine(MapFeature feature, Offset tap) {
    final points = feature.rings.single.map(screen).toList();
    for (var i = 1; i < points.length; i++) {
      final delta = points[i] - points[i - 1];
      final length = delta.dx * delta.dx + delta.dy * delta.dy;
      if (length == 0) continue;
      final relative = tap - points[i - 1];
      final fraction =
          ((relative.dx * delta.dx + relative.dy * delta.dy) / length).clamp(
            0.0,
            1.0,
          );
      if ((tap - (points[i - 1] + delta * fraction)).distance <= 10) {
        return true;
      }
    }
    return false;
  }

  Path shape(MapFeature f) {
    final path = Path()..fillType = PathFillType.evenOdd;
    for (final ring in f.rings) {
      for (var i = 0; i < ring.length; i++) {
        final p = screen(ring[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      if (f.type != 'LineString') path.close();
    }
    return path;
  }
}

class FloorPainter extends CustomPainter {
  FloorPainter(
    this.t,
    this.features,
    this.centres,
    this.preview,
    this.spacing,
    this.draft,
    this.selectedCentre,
    this.selectedFeature,
  );
  final MapTransform t;
  final List<MapFeature> features;
  final List<CaptureCentre> centres;
  final List<GeoPoint> preview, draft;
  final double spacing;
  final String? selectedCentre, selectedFeature;
  void label(
    Canvas canvas,
    String text,
    Offset point, {
    Color color = const Color(0xff20344a),
    double size = 11,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: 130);
    painter.paint(canvas, point);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfff0f4f8),
    );
    for (final f in features.where((f) => f.type == 'Polygon')) {
      final selected = f.id == selectedFeature;
      final fill = f.properties['fillColor'];
      Color color = f.isBoundary
          ? const Color(0xffe2e9f0)
          : const Color(0xffb9dbd4);
      if (fill is String && RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(fill)) {
        color = Color(int.parse('ff${fill.substring(1)}', radix: 16));
      }
      final shape = t.shape(f);
      canvas.drawPath(shape, Paint()..color = color.withValues(alpha: .7));
      canvas.drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = selected ? 3 : 1
          ..color = selected ? Colors.deepOrange : const Color(0xff6b8293),
      );
      if (!f.isBoundary) label(canvas, f.name, shape.getBounds().center);
    }
    for (final f in features.where((f) => f.type == 'LineString')) {
      final shape = t.shape(f);
      canvas.drawPath(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 4
          ..color = (f.properties['reviewed'] == true
              ? Colors.indigo
              : Colors.grey),
      );
      final direction = pathDirection(f);
      final points = f.rings.single;
      for (var i = 1; i < points.length; i++) {
        drawRouteArrows(
          canvas,
          t.screen(points[direction == PathDirection.reverse ? i : i - 1]),
          t.screen(points[direction == PathDirection.reverse ? i - 1 : i]),
          bothDirections: direction == PathDirection.both,
          color: f.properties['reviewed'] == true
              ? Colors.indigo.shade900
              : Colors.grey.shade700,
        );
      }
      label(canvas, f.name, t.screen(f.rings.first.first));
    }
    for (final p in preview) {
      final centre = t.screen(p), radius = spacing / math.sqrt(3) * t.scale;
      final hexagon = Path();
      for (var i = 0; i < 6; i++) {
        final angle = math.pi / 6 + i * math.pi / 3;
        final q =
            centre + Offset(math.cos(angle) * radius, math.sin(angle) * radius);
        if (i == 0) {
          hexagon.moveTo(q.dx, q.dy);
        } else {
          hexagon.lineTo(q.dx, q.dy);
        }
      }
      hexagon.close();
      canvas.drawPath(
        hexagon,
        Paint()..color = Colors.blue.withValues(alpha: .06),
      );
      canvas.drawPath(
        hexagon,
        Paint()
          ..color = Colors.blue.withValues(alpha: .35)
          ..style = PaintingStyle.stroke,
      );
      for (var i = 0; i < 6; i++) {
        final angle = math.pi / 6 + i * math.pi / 3;
        canvas.drawLine(
          centre,
          centre + Offset(math.cos(angle) * radius, math.sin(angle) * radius),
          Paint()..color = Colors.blue.withValues(alpha: .2),
        );
      }
      canvas.drawCircle(centre, 4, Paint()..color = Colors.blue);
    }
    for (final f in features.where((f) => f.isPoint)) {
      final point = t.screen(f.rings.first.first);
      canvas.drawCircle(
        point,
        f.id == selectedFeature ? 7 : 4,
        Paint()
          ..color = f.id == selectedFeature ? Colors.deepOrange : Colors.teal,
      );
      label(canvas, f.name, point + const Offset(6, -16));
    }
    for (final c in centres) {
      final p = t.screen(c.position), selected = c.id == selectedCentre;
      canvas.drawCircle(p, selected ? 12 : 9, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        selected ? 9 : 6,
        Paint()
          ..color = c.panoramas.isEmpty
              ? Colors.deepOrange
              : const Color(0xff1760be),
      );
      label(canvas, c.name, p + const Offset(10, 6));
    }
    if (draft.isNotEmpty) {
      final path = Path();
      for (var i = 0; i < draft.length; i++) {
        final p = t.screen(draft[i]);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
        canvas.drawCircle(p, 5, Paint()..color = Colors.purple);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.purple
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    label(canvas, '↑ N', const Offset(14, 14), size: 16);
    final barMetres = math
        .pow(10, (math.log(80 / t.scale) / math.ln10).floor())
        .toDouble();
    final length = barMetres * t.scale;
    canvas.drawLine(
      Offset(16, size.height - 25),
      Offset(16 + length, size.height - 25),
      Paint()
        ..strokeWidth = 3
        ..color = Colors.blueGrey,
    );
    label(
      canvas,
      '${barMetres < 1 ? barMetres.toStringAsFixed(1) : barMetres.round()} m',
      Offset(16, size.height - 46),
    );
  }

  @override
  bool shouldRepaint(FloorPainter oldDelegate) => true;
}
