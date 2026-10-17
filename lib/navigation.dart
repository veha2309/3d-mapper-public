import 'dart:math' as math;
import 'dart:convert';

import 'domain.dart';

/// Only explicitly reviewed path lines become edges. Geometric crossings do not
/// connect unless both paths contain the same annotated vertex.
class RouteNetwork {
  RouteNetwork(
    Iterable<MapFeature> features,
    this.floor, {
    bool includeUnreviewed = false,
  }) {
    final paths = features.where(
      (f) =>
          f.floor == floor &&
          f.type == 'LineString' &&
          (f.properties['reviewed'] == true || includeUnreviewed),
    );
    for (final path in paths) {
      final vertices = path.rings.single;
      for (var i = 0; i < vertices.length; i++) {
        final id = key(vertices[i]);
        nodes.putIfAbsent(
          id,
          () => RouteNode(id, '${path.name} · point ${i + 1}', vertices[i]),
        );
        if (i == 0) continue;
        final from = key(vertices[i - 1]);
        final distance = LocalFrame(vertices[i - 1])
            .project(vertices[i])
            .distance(const XY(0, 0));
        if (distance < .02 || distance > 1000) {
          throw const FormatException(
            'Path segments must be between 2 cm and 1 km',
          );
        }
        final direction = pathDirection(path);
        if (direction != PathDirection.reverse) {
          edges
              .putIfAbsent(from, () => [])
              .add(
                RouteEdge(
                  id,
                  distance,
                  path.name,
                  orientation: i == 1
                      ? path.properties['forward_start_cue'] as String?
                      : null,
                  note: path.properties['forward_note'] as String?,
                ),
              );
        }
        if (direction != PathDirection.forward) {
          edges
              .putIfAbsent(id, () => [])
              .add(
                RouteEdge(
                  from,
                  distance,
                  path.name,
                  orientation: i == vertices.length - 1
                      ? path.properties['reverse_start_cue'] as String?
                      : null,
                  note: path.properties['reverse_note'] as String?,
                ),
              );
        }
      }
    }
    for (final feature in features.where(
      (f) => f.floor == floor && f.isPoint,
    )) {
      final id = key(feature.rings.first.first);
      if (nodes.containsKey(id)) {
        nodes[id] = RouteNode(
          id,
          '${feature.properties['spoken_label'] ?? feature.name}',
          nodes[id]!.position,
          landmarkId: feature.id,
        );
      }
    }
  }
  final String floor;
  final nodes = <String, RouteNode>{};
  final edges = <String, List<RouteEdge>>{};
  static String key(GeoPoint p) =>
      '${p.lon.toStringAsFixed(9)},${p.lat.toStringAsFixed(9)}';

  RoutePlan plan(String from, String to) {
    if (!nodes.containsKey(from) || !nodes.containsKey(to)) {
      throw const FormatException('Select endpoints on this floor');
    }
    if (from == to) {
      throw const FormatException('Choose different route endpoints');
    }
    final distance = <String, double>{from: 0};
    final previous = <String, String>{};
    final previousEdges = <String, RouteEdge>{};
    final visited = <String>{};
    while (true) {
      final pending = distance.keys.where((k) => !visited.contains(k)).toList()
        ..sort((a, b) => distance[a]!.compareTo(distance[b]!));
      if (pending.isEmpty) {
        throw const FormatException(
          'No reviewed connected path between these points',
        );
      }
      final current = pending.first;
      if (current == to) break;
      visited.add(current);
      for (final edge in edges[current] ?? <RouteEdge>[]) {
        final cost = distance[current]! + edge.metres;
        if (cost < (distance[edge.to] ?? double.infinity)) {
          distance[edge.to] = cost;
          previous[edge.to] = current;
          previousEdges[edge.to] = edge;
        }
      }
    }
    final ordered = <RouteNode>[nodes[to]!];
    while (ordered.last.id != from) {
      ordered.add(nodes[previous[ordered.last.id]]!);
    }
    final routeNodes = ordered.reversed.toList();
    final neighbors = <String, Set<String>>{};
    for (final entry in edges.entries) {
      for (final edge in entry.value) {
        neighbors.putIfAbsent(entry.key, () => {}).add(edge.to);
        neighbors.putIfAbsent(edge.to, () => {}).add(entry.key);
      }
    }
    return RoutePlan(
      floor,
      routeNodes,
      distance[to]!,
      junctions: neighbors.entries
          .where((e) => e.value.length > 2)
          .map((e) => e.key)
          .toSet(),
      startOrientation: previousEdges[routeNodes[1].id]?.orientation,
      segmentNotes: routeNodes
          .skip(1)
          .map((n) => previousEdges[n.id]?.note)
          .toList(),
    );
  }
}

class RouteNode {
  const RouteNode(this.id, this.name, this.position, {this.landmarkId});
  final String id, name;
  final String? landmarkId;
  final GeoPoint position;
}

class RouteEdge {
  const RouteEdge(
    this.to,
    this.metres,
    this.name, {
    this.orientation,
    this.note,
  });
  final String to, name;
  final String? orientation, note;
  final double metres;
}

double bearing(GeoPoint from, GeoPoint to) {
  final delta = LocalFrame(from).project(to);
  return (math.atan2(delta.x, delta.y) * 180 / math.pi + 360) % 360;
}

String cardinal(double degrees) => [
  'north',
  'northeast',
  'east',
  'southeast',
  'south',
  'southwest',
  'west',
  'northwest',
][((degrees + 22.5) / 45).floor() % 8];
String relativeTurn(double before, double after) {
  final delta = (after - before + 540) % 360 - 180;
  if (delta.abs() < 25) return 'continue straight';
  if (delta.abs() > 155) return 'reverse direction';
  return 'turn ${delta > 0 ? 'right' : 'left'}';
}

enum RouteAction {
  start,
  straight,
  slightLeft,
  slightRight,
  left,
  right,
  sharpLeft,
  sharpRight,
  uTurn,
  finish,
}

RouteAction classifyTurn(double before, double after) {
  final change = (after - before + 540) % 360 - 180;
  final amount = change.abs();
  if (amount < 25) return RouteAction.straight;
  if (amount >= 160) return RouteAction.uTurn;
  if (amount < 55) {
    return change < 0 ? RouteAction.slightLeft : RouteAction.slightRight;
  }
  if (amount >= 125) {
    return change < 0 ? RouteAction.sharpLeft : RouteAction.sharpRight;
  }
  return change < 0 ? RouteAction.left : RouteAction.right;
}

String actionLabel(RouteAction action) => switch (action) {
  RouteAction.start => 'Start',
  RouteAction.straight => 'Continue straight',
  RouteAction.slightLeft => 'Bear slightly left',
  RouteAction.slightRight => 'Bear slightly right',
  RouteAction.left => 'Turn left',
  RouteAction.right => 'Turn right',
  RouteAction.sharpLeft => 'Turn sharply left',
  RouteAction.sharpRight => 'Turn sharply right',
  RouteAction.uTurn => 'Turn around',
  RouteAction.finish => 'Destination',
};
String distanceWords(double metres) {
  if (metres < 1) return 'less than 1 metre';
  final rounded = metres < 10
      ? (metres * 2).round() / 2
      : metres.roundToDouble();
  final text = rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
  return 'about $text ${rounded == 1 ? 'metre' : 'metres'}';
}

class RouteStep {
  const RouteStep({
    required this.action,
    required this.startIndex,
    required this.endIndex,
    required this.metres,
    required this.remainingMetres,
    required this.instruction,
    required this.context,
  });
  final RouteAction action;
  final int startIndex, endIndex;
  final double metres, remainingMetres;
  final String instruction;
  final List<String> context;
  String get title => actionLabel(action);
}

class RouteGuidance {
  const RouteGuidance(this.overview, this.orientation, this.steps);
  final String overview, orientation;
  final List<RouteStep> steps;
  String get spokenPreview => [
    'Route preview.',
    overview,
    orientation,
    for (var i = 0; i < steps.length; i++)
      'Step ${i + 1}. ${steps[i].instruction}',
  ].join(' ');
}

class RoutePlan {
  const RoutePlan(
    this.floor,
    this.nodes,
    this.metres, {
    this.junctions = const {},
    this.startOrientation,
    this.segmentNotes = const [],
  });
  final String floor;
  final List<RouteNode> nodes;
  final double metres;
  final Set<String> junctions;
  final String? startOrientation;
  final List<String?> segmentNotes;
  RouteGuidance guidance(Iterable<MapFeature> input) {
    if (nodes.length < 2) {
      return const RouteGuidance('No route selected.', '', []);
    }
    final landmarks = input
        .where((f) => f.floor == floor && f.isPoint)
        .toList();
    String spokenName(MapFeature feature) =>
        '${feature.properties['spoken_label'] ?? feature.name}'.trim();
    final counts = <String, int>{};
    for (final f in landmarks) {
      final name = spokenName(f).toLowerCase();
      counts[name] = (counts[name] ?? 0) + 1;
    }
    bool useful(MapFeature f) {
      final name = spokenName(f).toLowerCase();
      return name.isNotEmpty &&
          counts[name] == 1 &&
          !{
            'landmark',
            'point',
            'boundary',
            'workdesk',
            'workstation',
            'cabin',
            'door',
            'store',
          }.contains(name);
    }

    String? at(GeoPoint point) => landmarks
        .where(
          (f) =>
              useful(f) &&
              RouteNetwork.key(f.rings.first.first) == RouteNetwork.key(point),
        )
        .map(spokenName)
        .firstOrNull;
    final starts = <int>[0];
    for (var i = 1; i < nodes.length - 1; i++) {
      if (classifyTurn(
                bearing(nodes[i - 1].position, nodes[i].position),
                bearing(nodes[i].position, nodes[i + 1].position),
              ) !=
              RouteAction.straight ||
          junctions.contains(nodes[i].id)) {
        starts.add(i);
      }
    }
    starts.add(nodes.length - 1);
    final steps = <RouteStep>[];
    var traversed = 0.0;
    final usedContext = <String>{};
    for (var leg = 0; leg < starts.length - 1; leg++) {
      final first = starts[leg], last = starts[leg + 1];
      var length = 0.0;
      for (var i = first; i < last; i++) {
        length += LocalFrame(nodes[i].position)
            .project(nodes[i + 1].position)
            .distance(const XY(0, 0));
      }
      final action = first == 0
          ? RouteAction.start
          : classifyTurn(
              bearing(nodes[first - 1].position, nodes[first].position),
              bearing(nodes[first].position, nodes[first + 1].position),
            );
      final anchor = at(nodes[first].position),
          target = at(nodes[last].position);
      final beginning = first == 0
          ? (anchor == null ? 'From the selected start' : 'From $anchor')
          : (anchor == null
                ? (action == RouteAction.straight
                      ? 'At the junction, continue straight'
                      : 'At the bend, ${actionLabel(action).toLowerCase()}')
                : 'At $anchor, ${actionLabel(action).toLowerCase()}');
      final instruction = first == 0
          ? '$beginning, follow the path for ${distanceWords(length)}${target == null ? '' : ' to $target'}.'
          : '$beginning. Follow the path for ${distanceWords(length)}${target == null ? '' : ' to $target'}.';
      final context = <String>[];
      for (var i = first; i < last && i < segmentNotes.length; i++) {
        final note = segmentNotes[i]?.trim();
        if (note != null &&
            note.isNotEmpty &&
            !context.contains('Mapper note: $note')) {
          context.add('Mapper note: $note');
        }
      }
      final nearby = <({MapFeature feature, double along, double side})>[];
      var offset = 0.0;
      for (var i = first; i < last; i++) {
        final frame = LocalFrame(nodes[i].position),
            delta = LocalFrame(nodes[i].position)
                .project(nodes[i + 1].position);
        final segment = delta.distance(const XY(0, 0));
        for (final f in landmarks.where(useful)) {
          if (usedContext.contains(f.id) ||
              at(nodes[first].position) == spokenName(f) ||
              at(nodes[last].position) == spokenName(f)) {
            continue;
          }
          final p = frame.project(f.rings.first.first);
          final along = (p.x * delta.x + p.y * delta.y) / segment;
          final side = (delta.x * p.y - delta.y * p.x) / segment;
          if (along >= 0 && along <= segment && side.abs() <= 3) {
            nearby.add((feature: f, along: offset + along, side: side));
          }
        }
        offset += segment;
      }
      nearby.sort((a, b) => a.along.compareTo(b.along));
      for (final landmark in nearby) {
        if (context.where((s) => s.startsWith('Map reference:')).length >= 2) {
          break;
        }
        if (!usedContext.add(landmark.feature.id)) continue;
        final side = landmark.side.abs() < .5
            ? 'close to the path'
            : 'on the ${landmark.side > 0 ? 'left' : 'right'}';
        context.add(
          'Map reference: ${spokenName(landmark.feature)} is $side along this section. Visibility from the path is not confirmed.',
        );
      }
      steps.add(
        RouteStep(
          action: action,
          startIndex: first,
          endIndex: last,
          metres: length,
          remainingMetres: math.max(0, metres - traversed),
          instruction: instruction,
          context: context,
        ),
      );
      traversed += length;
    }
    final destination = nodes.last.landmarkId != null
        ? nodes.last.name
        : at(nodes.last.position);
    final arrival = arrivalPreview(
      bearing(nodes[nodes.length - 2].position, nodes.last.position),
      input,
    );
    steps.add(
      RouteStep(
        action: RouteAction.finish,
        startIndex: nodes.length - 1,
        endIndex: nodes.length - 1,
        metres: 0,
        remainingMetres: 0,
        instruction: arrival.announcement,
        context: const [
          'This is a planned endpoint, not a live arrival confirmation.',
        ],
      ),
    );
    final turns = steps
        .where(
          (s) =>
              s.action != RouteAction.start &&
              s.action != RouteAction.straight &&
              s.action != RouteAction.finish,
        )
        .length;
    final start = at(nodes.first.position) ?? 'Selected start';
    final end = destination ?? 'selected destination';
    final overview =
        '$start to $end: ${distanceWords(metres)}, with $turns ${turns == 1 ? 'turn' : 'turns'}. Floor $floor.';
    final orientation = startOrientation?.trim().isNotEmpty == true
        ? 'Starting orientation, supplied by the mapper: ${startOrientation!.trim()}'
        : 'The starting facing direction has not been described. The arrows show the planned direction; they do not measure which way you are facing.';
    return RouteGuidance(overview, orientation, steps);
  }

  List<String> describe(Iterable<MapFeature> features) {
    final result = guidance(features);
    return [
      result.overview,
      result.orientation,
      ...result.steps.map((s) => s.instruction),
    ];
  }
}

class ArrivalPreview {
  const ArrivalPreview(this.name, this.side, this.feature, this.reason);
  final String name;
  final String? side;
  final MapFeature? feature;
  final String reason;
  String get announcement =>
      'You have reached $name.${side == null ? '' : ' It is $side.'}';
  String get spoken => 'Arrival announcement preview. $announcement';
}

extension ArrivalRouteGuidance on RoutePlan {
  List<MapFeature> arrivalCandidates(Iterable<MapFeature> features) {
    if (nodes.isEmpty) return [];
    final frame = LocalFrame(nodes.last.position);
    final candidates = features
        .where(
          (f) =>
              f.floor == floor &&
              !f.isBoundary &&
              (f.isPoint || f.type == 'Polygon') &&
              _arrivalDistance(f, frame) <= 10,
        )
        .toList();
    candidates.sort(
      (a, b) =>
          _arrivalDistance(a, frame).compareTo(_arrivalDistance(b, frame)),
    );
    return candidates;
  }

  ArrivalPreview arrivalPreview(
    double heading,
    Iterable<MapFeature> input, {
    String? destinationFeatureId,
  }) {
    if (!heading.isFinite) throw ArgumentError('Arrival facing must be finite');
    final candidates = arrivalCandidates(input);
    final frame = LocalFrame(nodes.last.position);
    final selectedId = destinationFeatureId ?? nodes.last.landmarkId;
    final selected = candidates.where((f) => f.id == selectedId).firstOrNull;
    final nodeName = nodes.last.landmarkId != null
        ? nodes.last.name
        : 'your destination';
    final targetName = selected == null
        ? nodeName
        : '${selected.properties['spoken_label'] ?? selected.name}'.trim();
    MapFeature? target = selected;
    // A route point often marks a room entrance. A nearby same-name room area
    // supplies the side; duplicated point labels must not erase its identity.
    if (destinationFeatureId == null && (target == null || target.isPoint)) {
      final roomName = (target?.name ?? nodeName).trim().toLowerCase();
      final rooms = candidates
          .where(
            (f) =>
                f.type == 'Polygon' &&
                f.name.trim().toLowerCase() == roomName &&
                _arrivalDistance(f, frame) <= 2,
          )
          .toList();
      final distinct = <String, MapFeature>{};
      for (final room in rooms) {
        distinct.putIfAbsent(
          jsonEncode(room.toGeoJson()['geometry']),
          () => room,
        );
      }
      if (distinct.length == 1) target = distinct.values.single;
      if (distinct.length > 1) {
        return ArrivalPreview(
          targetName,
          null,
          selected,
          'Several nearby rooms share this name. Select the destination room to establish its side.',
        );
      }
    }
    if (target == null) {
      return ArrivalPreview(
        targetName,
        null,
        null,
        'Select the destination room or landmark to establish its side.',
      );
    }
    final angle = heading * math.pi / 180,
        ux = math.sin(angle),
        uy = math.cos(angle);
    if (target.isPoint) {
      final xy = frame.project(target.rings.first.first);
      if (xy.distance(const XY(0, 0)) < .25) {
        return ArrivalPreview(
          targetName,
          null,
          target,
          'The destination point is the arrival waypoint itself, so it does not establish a left/right side. Link the room area or its entrance location.',
        );
      }
      return ArrivalPreview(
        targetName,
        relativeSide(
          bearing(nodes.last.position, target.rings.first.first),
          heading,
        ),
        target,
        'Side comes from the selected landmark coordinate and preview facing.',
      );
    }
    final points = target.rings.first.map(frame.project).toList();
    final lateral = points.map((p) => ux * p.y - uy * p.x).toList();
    final along = points.map((p) => ux * p.x + uy * p.y).toList();
    String? side;
    if (lateral.reduce(math.min) >= -.25 && lateral.reduce(math.max) > .5) {
      side = 'on your left';
    } else if (lateral.reduce(math.max) <= .25 &&
        lateral.reduce(math.min) < -.5) {
      side = 'on your right';
    } else if (along.reduce(math.min) >= -.25 && along.reduce(math.max) > .5) {
      side = 'ahead';
    } else if (along.reduce(math.max) <= .25 && along.reduce(math.min) < -.5) {
      side = 'behind you';
    }
    return ArrivalPreview(
      targetName,
      side,
      target,
      side == null
          ? 'The destination area spans more than one side of this waypoint. A specific entrance annotation is needed.'
          : 'Side comes from the destination room area and preview facing; it does not locate the exact doorway.',
    );
  }
}

double _arrivalDistance(MapFeature feature, LocalFrame frame) {
  final origin = const XY(0, 0);
  if (feature.isPoint) {
    return frame.project(feature.rings.first.first).distance(origin);
  }
  final rings = feature.rings
      .map((r) => r.map(frame.project).toList())
      .toList();
  if (containsPolygon(origin, rings)) return 0;
  var best = double.infinity;
  for (final ring in rings) {
    for (var i = 1; i < ring.length; i++) {
      final a = ring[i - 1], b = ring[i], dx = b.x - a.x, dy = b.y - a.y;
      final square = dx * dx + dy * dy;
      final t = square == 0
          ? 0.0
          : ((-a.x * dx - a.y * dy) / square).clamp(0.0, 1.0);
      best = math.min(best, XY(a.x + t * dx, a.y + t * dy).distance(origin));
    }
  }
  return best;
}

class FacingLandmark {
  const FacingLandmark(
    this.name,
    this.relative,
    this.bearingDegrees,
    this.metres,
  );
  final String name, relative;
  final double bearingDegrees, metres;
  String get text =>
      '$name is $relative, toward the ${cardinal(bearingDegrees)}, ${distanceWords(metres)} from this waypoint.';
}

class FacingScene {
  const FacingScene(
    this.heading,
    this.header,
    this.alignmentAction,
    this.alignment,
    this.landmarks,
  );
  final double heading;
  final String header, alignment;
  final RouteAction alignmentAction;
  final List<FacingLandmark> landmarks;
  String get spoken =>
      [header, for (final landmark in landmarks) landmark.text].join(' ');
}

String relativeSide(double bearingDegrees, double headingDegrees) {
  final angle = (bearingDegrees - headingDegrees + 360) % 360;
  return [
    'ahead',
    'ahead on your right',
    'on your right',
    'behind on your right',
    'behind you',
    'behind on your left',
    'on your left',
    'ahead on your left',
  ][((angle + 22.5) / 45).floor() % 8];
}

extension FacingRouteGuidance on RoutePlan {
  FacingScene facingScene(
    RouteStep step,
    double heading,
    Iterable<MapFeature> input,
  ) {
    if (!heading.isFinite) {
      throw ArgumentError('Facing direction must be finite');
    }
    final normalized = (heading % 360 + 360) % 360;
    final origin = nodes[step.startIndex].position;
    final points = input.where((f) => f.floor == floor && f.isPoint).toList();
    String name(MapFeature f) =>
        '${f.properties['spoken_label'] ?? f.name}'.trim();
    final counts = <String, int>{};
    for (final f in points) {
      final key = name(f).toLowerCase();
      counts[key] = (counts[key] ?? 0) + 1;
    }
    bool useful(MapFeature f) {
      final value = name(f).toLowerCase();
      return value.isNotEmpty &&
          counts[value] == 1 &&
          !{
            'point',
            'landmark',
            'boundary',
            'cabin',
            'door',
            'workdesk',
            'workstation',
            'store',
          }.contains(value);
    }

    final anchor = points
        .where(
          (f) =>
              useful(f) &&
              RouteNetwork.key(f.rings.first.first) == RouteNetwork.key(origin),
        )
        .map(name)
        .firstOrNull;
    final header =
        'Preview: facing ${cardinal(normalized)} at ${anchor ?? 'this waypoint'}.';
    final landmarks = <FacingLandmark>[];
    final frame = LocalFrame(origin);
    for (final feature in points.where(useful)) {
      final point = feature.rings.first.first;
      final metres = frame.project(point).distance(const XY(0, 0));
      if (metres < .25 || metres > 10) continue;
      final angle = bearing(origin, point);
      landmarks.add(
        FacingLandmark(
          name(feature),
          relativeSide(angle, normalized),
          angle,
          metres,
        ),
      );
    }
    landmarks.sort((a, b) => a.metres.compareTo(b.metres));
    if (step.action == RouteAction.finish) {
      return FacingScene(
        normalized,
        header,
        RouteAction.finish,
        'This is the planned destination waypoint, not a live arrival confirmation.',
        landmarks.take(4).toList(),
      );
    }
    final target = bearing(origin, nodes[step.startIndex + 1].position);
    final action = classifyTurn(normalized, target);
    final alignment = action == RouteAction.straight
        ? 'The next section is ahead, toward ${cardinal(target)}. Follow the path for ${distanceWords(step.metres)}.'
        : '${actionLabel(action)} to face ${cardinal(target)}, then follow the path for ${distanceWords(step.metres)}.';
    return FacingScene(
      normalized,
      header,
      action,
      alignment,
      landmarks.take(4).toList(),
    );
  }
}

/// Interface for the future map-aligned metric pose provider. Recognition IDs
/// alone cannot construct a pose. Limits are pilot policy, not validated accuracy.
class MetricPoseFix {
  const MetricPoseFix({
    required this.position,
    required this.floor,
    required this.headingDegrees,
    required this.uncertaintyMetres,
    required this.headingUncertaintyDegrees,
    required this.timestampMs,
    required this.mapAligned,
  });
  final GeoPoint position;
  final String floor;
  final double headingDegrees, uncertaintyMetres, headingUncertaintyDegrees;
  final int timestampMs;
  final bool mapAligned;
  bool usable(String routeFloor, int nowMs) =>
      mapAligned &&
      floor == routeFloor &&
      nowMs >= timestampMs &&
      nowMs - timestampMs <= 1500 &&
      headingDegrees.isFinite &&
      uncertaintyMetres.isFinite &&
      uncertaintyMetres >= 0 &&
      uncertaintyMetres <= .75 &&
      headingUncertaintyDegrees.isFinite &&
      headingUncertaintyDegrees >= 0 &&
      headingUncertaintyDegrees <= 15 &&
      position.lon.isFinite &&
      position.lat.isFinite &&
      position.lon.abs() <= 180 &&
      position.lat.abs() <= 85;
}
