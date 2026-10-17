import 'dart:convert';
import 'dart:math' as math;

import 'labels.dart';
export 'labels.dart';

typedef Json = Map<String, dynamic>;
String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${math.Random.secure().nextInt(0x7fffffff).toRadixString(36)}';

class GeoPoint {
  const GeoPoint(this.lon, this.lat);
  final double lon, lat;
  factory GeoPoint.parse(dynamic value) {
    if (value is! List ||
        value.length < 2 ||
        value[0] is! num ||
        value[1] is! num) {
      throw const FormatException('Expected [longitude, latitude]');
    }
    final lon = (value[0] as num).toDouble(),
        lat = (value[1] as num).toDouble();
    if (!lon.isFinite || !lat.isFinite || lon.abs() > 180 || lat.abs() > 85) {
      throw const FormatException(
        'Coordinates must be finite WGS84 longitude/latitude (latitude within ±85°)',
      );
    }
    return GeoPoint(lon, lat);
  }
  List<double> toJson() => [lon, lat];
}

class XY {
  const XY(this.x, this.y);
  final double x, y;
  double distance(XY b) =>
      math.sqrt(math.pow(x - b.x, 2) + math.pow(y - b.y, 2));
}

class LocalFrame {
  LocalFrame(this.origin);
  final GeoPoint origin;
  static const radius = 6378137.0;
  double get _scale => math.cos(origin.lat * math.pi / 180);
  XY project(GeoPoint p) => XY(
    (p.lon - origin.lon) * math.pi / 180 * radius * _scale,
    (p.lat - origin.lat) * math.pi / 180 * radius,
  );
  GeoPoint unproject(XY p) => GeoPoint(
    origin.lon + p.x / (radius * _scale) * 180 / math.pi,
    origin.lat + p.y / radius * 180 / math.pi,
  );
}

enum PathDirection { both, forward, reverse }

PathDirection pathDirection(MapFeature feature) =>
    switch (feature.properties['travel_direction']) {
      'forward' => PathDirection.forward,
      'reverse' => PathDirection.reverse,
      _ =>
        feature.properties['oneway'] == true
            ? PathDirection.forward
            : PathDirection.both,
    };

class MapFeature {
  MapFeature(
    this.id,
    this.name,
    this.floor,
    this.type,
    this.rings,
    this.properties,
  );
  final String id, name, floor, type;
  final List<List<GeoPoint>> rings;
  final Json properties;
  bool get isPoint => type == 'Point';
  bool get isBoundary =>
      '${properties['type'] ?? properties['category'] ?? ''}'.toLowerCase() ==
      'boundary';
  Iterable<GeoPoint> get points => rings.expand((r) => r);
  Json toGeoJson() => {
    'type': 'Feature',
    'id': id,
    'properties': {...properties, 'name': name, 'floor': floor},
    'geometry': {
      'type': type,
      'coordinates': isPoint
          ? rings.first.first.toJson()
          : type == 'LineString'
          ? rings.single.map((p) => p.toJson()).toList()
          : rings.map((r) => r.map((p) => p.toJson()).toList()).toList(),
    },
  };
}

class MapData {
  MapData(this.features, this.warnings);
  final List<MapFeature> features;
  final List<String> warnings;
  factory MapData.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('Map must be a JSON object');
    }
    final dynamic entries = decoded['type'] == 'FeatureCollection'
        ? decoded['features']
        : decoded['data'];
    if (entries is! List) {
      throw const FormatException(
        'Expected GeoJSON FeatureCollection or office {data: [...]}',
      );
    }
    final features = <MapFeature>[], warnings = <String>[];
    final ids = <String>{};
    for (var i = 0; i < entries.length; i++) {
      try {
        final raw = Map<String, dynamic>.from(entries[i] as Map);
        final properties = Map<String, dynamic>.from(
          raw['properties'] as Map? ?? {},
        );
        final geometry = Map<String, dynamic>.from(raw['geometry'] as Map);
        final id = '${raw['id'] ?? properties['landmarkId'] ?? 'source-$i'}';
        if (!ids.add(id)) throw FormatException('Duplicate feature ID $id');
        final type = geometry['type'] as String;
        final coordinates = geometry['coordinates'];
        List<List<GeoPoint>> rings;
        if (type == 'Point') {
          rings = [
            [GeoPoint.parse(coordinates)],
          ];
        } else if (type == 'LineString') {
          if (coordinates is! List || coordinates.length < 2) {
            throw const FormatException('A path needs at least two points');
          }
          final line = coordinates.map(GeoPoint.parse).toList();
          for (var j = 1; j < line.length; j++) {
            final length = LocalFrame(line[j - 1])
                .project(line[j])
                .distance(const XY(0, 0));
            if (length < .02 || length > 1000) {
              throw const FormatException(
                'Path segments must be between 2 cm and 1 km',
              );
            }
          }
          if (properties['reviewed'] != null &&
              properties['reviewed'] is! bool) {
            throw const FormatException('Path reviewed must be boolean');
          }
          if (properties['oneway'] != null && properties['oneway'] is! bool) {
            throw const FormatException('Path oneway must be boolean');
          }
          final direction = properties['travel_direction'];
          if (direction != null &&
              !['both', 'forward', 'reverse'].contains(direction)) {
            throw const FormatException('Invalid path travel direction');
          }
          if (direction == 'both' && properties['oneway'] == true) {
            throw const FormatException('Conflicting path direction settings');
          }
          for (final key in [
            'forward_start_cue',
            'reverse_start_cue',
            'forward_note',
            'reverse_note',
          ]) {
            if (properties[key] != null &&
                (properties[key] is! String ||
                    (properties[key] as String).length > 500)) {
              throw FormatException(
                'Path $key must be text of at most 500 characters',
              );
            }
          }
          rings = [line];
        } else if (type == 'Polygon') {
          if (coordinates is! List || coordinates.isEmpty) {
            throw const FormatException('Empty polygon');
          }
          final List<dynamic> lists =
              coordinates.first is List &&
                  (coordinates.first as List).firstOrNull is num
              ? [coordinates]
              : coordinates;
          rings = lists
              .map((r) => (r as List).map(GeoPoint.parse).toList())
              .toList();
          for (final ring in rings) {
            if (ring.length < 4 ||
                ring.first.lon != ring.last.lon ||
                ring.first.lat != ring.last.lat) {
              throw const FormatException(
                'Polygon rings need at least 4 positions and must be closed',
              );
            }
            final frame = LocalFrame(ring.first);
            final vertices = ring.map(frame.project).toList();
            var area = 0.0;
            for (var j = 0; j < vertices.length - 1; j++) {
              area +=
                  vertices[j].x * vertices[j + 1].y -
                  vertices[j + 1].x * vertices[j].y;
            }
            if (area.abs() < 0.0001) {
              throw const FormatException('Zero-area polygon');
            }
          }
        } else {
          throw FormatException('Unsupported geometry $type');
        }
        features.add(
          MapFeature(
            id,
            '${properties['name'] ?? properties['spoken_label'] ?? id}',
            '${properties['floor'] ?? properties['level'] ?? 0}',
            type,
            rings,
            properties,
          ),
        );
      } catch (e) {
        warnings.add('Feature ${i + 1}: $e (retained in source map)');
      }
    }
    if (features.isEmpty) {
      throw FormatException(
        'No usable Point/Polygon/LineString features. ${warnings.join('; ')}',
      );
    }
    return MapData(features, warnings);
  }
}

bool containsRing(XY p, List<XY> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    final dx = b.x - a.x, dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared > 0) {
      final fraction = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared;
      if (fraction >= 0 &&
          fraction <= 1 &&
          p.distance(XY(a.x + fraction * dx, a.y + fraction * dy)) < 1e-6) {
        return true;
      }
    }
    if ((a.y > p.y) != (b.y > p.y) &&
        p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

bool containsPolygon(XY p, List<List<XY>> rings) =>
    containsRing(p, rings.first) &&
    !rings.skip(1).any((r) => containsRing(p, r));

class GridSettings {
  GridSettings(this.floor, this.spacing, this.origin);
  final String floor;
  final double spacing;
  final GeoPoint origin;
  Json toJson() => {
    'floor': floor,
    'spacing_m': spacing,
    'origin': origin.toJson(),
  };
  factory GridSettings.fromJson(Json j) {
    final spacing = (j['spacing_m'] as num).toDouble();
    if (!spacing.isFinite || spacing < .5 || spacing > 100) {
      throw const FormatException('Grid spacing must be 0.5–100 m');
    }
    return GridSettings(
      j['floor'] as String,
      spacing,
      GeoPoint.parse(j['origin']),
    );
  }
}

List<GeoPoint> generateGrid(List<MapFeature> features, GridSettings settings) {
  final floor = features.where((f) => f.floor == settings.floor).toList();
  if (floor.isEmpty) return [];
  if (!settings.spacing.isFinite ||
      settings.spacing < .5 ||
      settings.spacing > 100) {
    throw const FormatException('Grid spacing must be 0.5–100 m');
  }
  final frame = LocalFrame(settings.origin);
  final points = floor.expand((f) => f.points).map(frame.project).toList();
  final minX = points.map((p) => p.x).reduce(math.min),
      maxX = points.map((p) => p.x).reduce(math.max);
  final minY = points.map((p) => p.y).reduce(math.min),
      maxY = points.map((p) => p.y).reduce(math.max);
  final stepY = settings.spacing * math.sqrt(3) / 2;
  if ((maxX - minX + settings.spacing) /
          settings.spacing *
          ((maxY - minY + stepY) / stepY) >
      10000) {
    throw const FormatException(
      'Grid exceeds 10,000 candidate centres. Increase spacing or use a smaller map.',
    );
  }
  final boundaries = floor
      .where((f) => f.isBoundary && f.type == 'Polygon')
      .map((f) => f.rings.map((r) => r.map(frame.project).toList()).toList())
      .toList();
  final result = <GeoPoint>[];
  for (var row = (minY / stepY).floor(); row <= (maxY / stepY).ceil(); row++) {
    final offset = row.isOdd ? settings.spacing / 2 : 0.0;
    for (
      var col = ((minX - offset) / settings.spacing).floor();
      col <= ((maxX - offset) / settings.spacing).ceil();
      col++
    ) {
      final p = XY(col * settings.spacing + offset, row * stepY);
      if (p.x < minX || p.x > maxX || p.y < minY || p.y > maxY) continue;
      if (boundaries.isNotEmpty &&
          !boundaries.any((rings) => containsPolygon(p, rings))) {
        continue;
      }
      result.add(frame.unproject(p));
    }
  }
  return result;
}

class Panorama {
  Panorama(this.id, this.path, this.heading, [List<PanoramaLabel>? labels])
    : labels = labels ?? [];
  final String id, path;
  double heading;
  final List<PanoramaLabel> labels;
  Json toJson() => {
    'id': id,
    'path': path,
    'heading_deg': heading,
    'labels': labels.map((label) => label.toJson()).toList(),
  };
  factory Panorama.fromJson(Json j) {
    final h = (j['heading_deg'] as num).toDouble();
    if (!h.isFinite) throw const FormatException('Invalid panorama heading');
    return Panorama(
      j['id'] as String,
      j['path'] as String,
      h % 360,
      (j['labels'] as List? ?? [])
          .map((v) => PanoramaLabel.fromJson(Map<String, dynamic>.from(v)))
          .toList(),
    );
  }
}

class CaptureCentre {
  CaptureCentre(
    this.id,
    this.name,
    this.floor,
    this.position, [
    List<Panorama>? panoramas,
  ]) : panoramas = panoramas ?? [];
  final String id, floor;
  String name;
  GeoPoint position;
  final List<Panorama> panoramas;
  Json toJson() => {
    'id': id,
    'name': name,
    'floor': floor,
    'position': position.toJson(),
    'panoramas': panoramas.map((p) => p.toJson()).toList(),
  };
  factory CaptureCentre.fromJson(Json j) => CaptureCentre(
    j['id'] as String,
    j['name'] as String,
    j['floor'] as String,
    GeoPoint.parse(j['position']),
    (j['panoramas'] as List)
        .map((p) => Panorama.fromJson(Map<String, dynamic>.from(p)))
        .toList(),
  );
}

class MapperProject {
  MapperProject(
    this.id,
    this.name,
    this.source,
    this.sourceData, {
    List<MapFeature>? annotations,
    List<CaptureCentre>? centres,
    List<GridSettings>? grids,
  }) : annotations = annotations ?? [],
       centres = centres ?? [],
       grids = grids ?? [];
  final String id, source;
  String name;
  final MapData sourceData;
  final List<MapFeature> annotations;
  final List<CaptureCentre> centres;
  final List<GridSettings> grids;
  Iterable<MapFeature> get features {
    final overridden = annotations
        .map((f) => f.properties['source_feature_id'])
        .whereType<String>()
        .toSet();
    return [
      ...sourceData.features.where((f) => !overridden.contains(f.id)),
      ...annotations.where((f) => f.properties['_mapper_deleted'] != true),
    ];
  }

  List<String> get floors => [
    ...sourceData.features,
    ...annotations,
  ].map((f) => f.floor).toSet().toList()..sort();
  Json toJson() => {
    'version': 6,
    'id': id,
    'name': name,
    'source_map': 'source.json',
    'annotations': annotations.map((f) => f.toGeoJson()).toList(),
    'capture_centres': centres.map((c) => c.toJson()).toList(),
    'grids': grids.map((g) => g.toJson()).toList(),
  };
  factory MapperProject.fromJson(Json j, String source) {
    if (![1, 2, 3, 4, 5, 6].contains(j['version']) ||
        j['source_map'] != 'source.json') {
      throw const FormatException('Unsupported project version or source map');
    }
    final annotationList = j['annotations'] as List;
    final parsed = annotationList.isEmpty
        ? MapData([], [])
        : MapData.parse(
            jsonEncode({
              'type': 'FeatureCollection',
              'features': annotationList,
            }),
          );
    if (parsed.warnings.isNotEmpty) {
      throw FormatException(
        'Invalid editable annotations: ${parsed.warnings.join('; ')}',
      );
    }
    final project = MapperProject(
      j['id'] as String,
      j['name'] as String,
      source,
      MapData.parse(source),
      annotations: parsed.features,
      centres: (j['capture_centres'] as List)
          .map((c) => CaptureCentre.fromJson(Map<String, dynamic>.from(c)))
          .toList(),
      grids: (j['grids'] as List)
          .map((g) => GridSettings.fromJson(Map<String, dynamic>.from(g)))
          .toList(),
    );
    final ids = <String>{};
    final panoramaIds = <String>{};
    final labelIds = <String>{};
    final viewIds = <String>{};
    final referencePaths = <String>{};
    final photoIds = <String>{}, originalPaths = <String>{};
    for (final c in project.centres) {
      if (c.id.isEmpty || !ids.add(c.id) || !project.floors.contains(c.floor)) {
        throw const FormatException(
          'Invalid/duplicate centre ID or unknown floor',
        );
      }
      for (final p in c.panoramas) {
        if (p.id.isEmpty || !panoramaIds.add(p.id)) {
          throw const FormatException('Duplicate panorama ID');
        }
        for (final label in p.labels) {
          if (label.id.isEmpty ||
              !labelIds.add(label.id) ||
              !viewIds.add(label.id) ||
              !referencePaths.add(label.referencePath)) {
            throw const FormatException(
              'Duplicate panorama label ID or reference path',
            );
          }
          for (final photo in label.photos) {
            if (photo.id.isEmpty ||
                !photoIds.add(photo.id) ||
                !viewIds.add(photo.id) ||
                !referencePaths.add(photo.referencePath) ||
                !originalPaths.add(photo.originalPath)) {
              throw const FormatException(
                'Duplicate supporting photo ID or asset path',
              );
            }
          }
        }
      }
    }
    return project;
  }
}
