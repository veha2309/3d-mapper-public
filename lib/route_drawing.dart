import 'dart:math' as math;

import 'package:flutter/material.dart';

void drawRouteArrows(
  Canvas canvas,
  Offset a,
  Offset b, {
  Color color = Colors.indigo,
  double zoom = 1,
  bool bothDirections = false,
}) {
  final delta = b - a, length = delta.distance;
  if (length * zoom < 28) return;
  final direction = delta / length,
      normal = Offset(-direction.dy, direction.dx);
  final count = math.max(bothDirections ? 2 : 1, (length * zoom / 100).floor());
  for (var i = 0; i < count; i++) {
    final centre = a + delta * ((i + .5) / count);
    final travel = bothDirections && i.isOdd ? -direction : direction;
    final tip = centre + travel * (7 / zoom),
        base = centre - travel * (5 / zoom);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          (base + normal * (5 / zoom)).dx,
          (base + normal * (5 / zoom)).dy,
        )
        ..lineTo(
          (base - normal * (5 / zoom)).dx,
          (base - normal * (5 / zoom)).dy,
        )
        ..close(),
      Paint()..color = color,
    );
  }
}

void drawRouteBadge(
  Canvas canvas,
  Offset point,
  String text,
  Color color, {
  double zoom = 1,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: Colors.white,
        fontSize: 12 / zoom,
        fontWeight: FontWeight.bold,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final rect = Rect.fromCenter(
    center: point,
    width: math.max(26 / zoom, painter.width + 12 / zoom),
    height: 26 / zoom,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(13 / zoom)),
    Paint()..color = color,
  );
  canvas.drawRRect(
    RRect.fromRectAndRadius(rect, Radius.circular(13 / zoom)),
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 / zoom
      ..color = Colors.white,
  );
  painter.paint(canvas, point - Offset(painter.width / 2, painter.height / 2));
}
