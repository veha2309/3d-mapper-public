import 'domain.dart';

/// Geometry-only undo history. Saving/reviewing is managed by the editor.
class PathDraft {
  PathDraft([List<GeoPoint> initial = const []]) : points = List.of(initial);
  List<GeoPoint> points;
  final _undo = <List<GeoPoint>>[], _redo = <List<GeoPoint>>[];
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  void commit(List<GeoPoint> next) {
    if (next.length == points.length &&
        List.generate(
          next.length,
          (i) => next[i].lon == points[i].lon && next[i].lat == points[i].lat,
        ).every((v) => v)) {
      return;
    }
    _undo.add(List.of(points));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
    points = List.of(next);
  }

  void undo() {
    if (!canUndo) return;
    _redo.add(List.of(points));
    points = _undo.removeLast();
  }

  void redo() {
    if (!canRedo) return;
    _undo.add(List.of(points));
    points = _redo.removeLast();
  }

  double get metres {
    var result = 0.0;
    for (var i = 1; i < points.length; i++) {
      result += LocalFrame(points[i - 1])
          .project(points[i])
          .distance(const XY(0, 0));
    }
    return result;
  }

  String? get problem {
    if (points.length < 2) return 'Place at least two points to make a path.';
    for (var i = 1; i < points.length; i++) {
      final length = LocalFrame(points[i - 1])
          .project(points[i])
          .distance(const XY(0, 0));
      if (length < .02) {
        return 'Points $i and ${i + 1} overlap. Move or remove one.';
      }
      if (length > 1000) return 'A segment exceeds 1 km. Check your map scale.';
    }
    return null;
  }
}
