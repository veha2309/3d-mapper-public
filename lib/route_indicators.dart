import 'package:flutter/material.dart';

import 'dart:math' as math;

import 'domain.dart';
import 'map_view.dart';
import 'navigation.dart';
import 'route_drawing.dart';
export 'route_drawing.dart';

IconData routeIcon(RouteAction action) => switch (action) {
  RouteAction.start => Icons.flag_outlined,
  RouteAction.finish => Icons.location_on,
  RouteAction.straight => Icons.straight,
  RouteAction.left => Icons.turn_left,
  RouteAction.right => Icons.turn_right,
  RouteAction.slightLeft => Icons.turn_slight_left,
  RouteAction.slightRight => Icons.turn_slight_right,
  RouteAction.sharpLeft => Icons.turn_sharp_left,
  RouteAction.sharpRight => Icons.turn_sharp_right,
  RouteAction.uTurn => Icons.u_turn_left,
};

class RouteDiagram extends StatefulWidget {
  const RouteDiagram({
    super.key,
    required this.features,
    required this.plan,
    required this.guidance,
    required this.selected,
    required this.onStep,
    this.facingHeading,
    this.destinationFeatureId,
  });
  final List<MapFeature> features;
  final RoutePlan plan;
  final RouteGuidance guidance;
  final int selected;
  final double? facingHeading;
  final String? destinationFeatureId;
  final void Function(int) onStep;
  @override
  State<RouteDiagram> createState() => _RouteDiagramState();
}

class _RouteDiagramState extends State<RouteDiagram> {
  final viewport = TransformationController();
  @override
  void dispose() {
    viewport.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Planned route map. Start S, destination D, numbered steps and arrows. No current-position marker.',
    child: Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            // Fit the selected route; do not shrink it to an entire building's extent.
            final bounds = [
              MapFeature('route-bounds', '', '', 'LineString', [
                widget.plan.nodes.map((n) => n.position).toList(),
              ], {}),
            ];
            final transform = MapTransform(bounds, [], size);
            return ClipRect(
              child: InteractiveViewer(
                transformationController: viewport,
                minScale: .5,
                maxScale: 12,
                boundaryMargin: const EdgeInsets.all(250),
                child: GestureDetector(
                  onTapUp: (event) {
                    var closest = 20 / viewport.value.getMaxScaleOnAxis();
                    int? step;
                    for (var i = 0; i < widget.guidance.steps.length; i++) {
                      final point = widget
                          .plan
                          .nodes[widget.guidance.steps[i].startIndex]
                          .position;
                      final distance =
                          (transform.screen(point) - event.localPosition)
                              .distance;
                      if (distance < closest) {
                        closest = distance;
                        step = i;
                      }
                    }
                    if (step != null) widget.onStep(step);
                  },
                  child: SizedBox.fromSize(
                    size: size,
                    child: AnimatedBuilder(
                      animation: viewport,
                      builder: (context, _) => CustomPaint(
                        key: const ValueKey('route-diagram'),
                        painter: FloorPainter(
                          transform,
                          widget.features
                              .where((f) => f.type == 'Polygon')
                              .toList(),
                          [],
                          [],
                          1,
                          [],
                          null,
                          widget.destinationFeatureId,
                        ),
                        foregroundPainter: _RouteDiagramPainter(
                          transform,
                          widget.plan,
                          widget.guidance,
                          widget.selected,
                          viewport.value.getMaxScaleOnAxis(),
                          widget.facingHeading,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton.filledTonal(
            tooltip: 'Fit route',
            onPressed: () => viewport.value = Matrix4.identity(),
            icon: const Icon(Icons.fit_screen),
          ),
        ),
        if (widget.facingHeading != null)
          Positioned(
            left: 8,
            right: 64,
            top: 8,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  'Preview facing: ${cardinal(widget.facingHeading!)} · purple arrow',
                ),
              ),
            ),
          ),
        const Positioned(
          left: 8,
          bottom: 8,
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                'S Start · D Destination\nOrange: selected step · arrows: travel direction',
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _RouteDiagramPainter extends CustomPainter {
  _RouteDiagramPainter(
    this.transform,
    this.plan,
    this.guidance,
    this.selected,
    this.zoom,
    this.facingHeading,
  );
  final MapTransform transform;
  final RoutePlan plan;
  final RouteGuidance guidance;
  final int selected;
  final double zoom;
  final double? facingHeading;
  @override
  void paint(Canvas canvas, Size size) {
    final step = guidance.steps[selected];
    for (var i = 1; i < plan.nodes.length; i++) {
      final a = transform.screen(plan.nodes[i - 1].position),
          b = transform.screen(plan.nodes[i].position);
      final active = i > step.startIndex && i <= step.endIndex;
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 10 / zoom
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = (active ? Colors.deepOrange : Colors.indigo)
          ..strokeWidth = 6 / zoom
          ..strokeCap = StrokeCap.round,
      );
      drawRouteArrows(canvas, a, b, color: Colors.white, zoom: zoom);
    }
    if (facingHeading != null) {
      final origin = transform.screen(plan.nodes[step.startIndex].position);
      final angle = facingHeading! * math.pi / 180;
      final tip =
          origin +
          Offset(math.sin(angle) * 38 / zoom, -math.cos(angle) * 38 / zoom);
      canvas.drawLine(
        origin,
        tip,
        Paint()
          ..color = Colors.purple
          ..strokeWidth = 4 / zoom,
      );
      drawRouteArrows(canvas, origin, tip, color: Colors.purple, zoom: zoom);
    }
    for (var i = 0; i < guidance.steps.length; i++) {
      final s = guidance.steps[i];
      drawRouteBadge(
        canvas,
        transform.screen(plan.nodes[s.startIndex].position),
        s.action == RouteAction.start
            ? 'S'
            : s.action == RouteAction.finish
            ? 'D'
            : '${i + 1}',
        i == selected
            ? Colors.deepOrange
            : s.action == RouteAction.start
            ? Colors.teal
            : s.action == RouteAction.finish
            ? Colors.red.shade700
            : Colors.indigo,
        zoom: zoom,
      );
    }
  }

  @override
  bool shouldRepaint(_RouteDiagramPainter oldDelegate) => true;
}
