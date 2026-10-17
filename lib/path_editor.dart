import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'domain.dart';
import 'map_view.dart';
import 'path_draft.dart';
import 'storage.dart';
import 'navigation.dart';
import 'route_indicators.dart';

enum PathEditMode { draw, vertices, insert, pan }

class PathEditorPage extends StatefulWidget {
  const PathEditorPage({
    super.key,
    required this.project,
    required this.store,
    required this.floor,
    this.initialPath,
  });
  final MapperProject project;
  final ProjectStore store;
  final String floor;
  final MapFeature? initialPath;
  @override
  State<PathEditorPage> createState() => _PathEditorPageState();
}

class _PathEditorPageState extends State<PathEditorPage> {
  final name = TextEditingController();
  final forwardCue = TextEditingController(),
      reverseCue = TextEditingController();
  final forwardNote = TextEditingController(),
      reverseNote = TextEditingController();
  RouteGuidance get drawingGuidance {
    final reversed =
        direction == PathDirection.reverse ||
        (direction == PathDirection.both && reversePreview);
    final points = reversed ? draft.points.reversed.toList() : draft.points;
    return RoutePlan(
      widget.floor,
      [
        for (var i = 0; i < points.length; i++)
          RouteNode('draft-$i', '', points[i]),
      ],
      draft.metres,
      startOrientation: reversed ? reverseCue.text : forwardCue.text,
    ).guidance(features);
  }

  final viewport = TransformationController();
  final focus = FocusNode();
  PathDraft draft = PathDraft();
  MapFeature? editing;
  PathEditMode mode = PathEditMode.draw;
  PathDirection direction = PathDirection.both;
  bool reversePreview = false;
  int? selected;
  bool reviewed = false, dirty = false, busy = false, allowPop = false;
  String status =
      'Click the map to place the start, bends and destination. Drag to pan; scroll to zoom.';
  List<MapFeature> get features =>
      widget.project.features.where((f) => f.floor == widget.floor).toList();
  List<MapFeature> get paths =>
      features.where((f) => f.type == 'LineString').toList();
  @override
  void initState() {
    super.initState();
    load(widget.initialPath);
  }

  void load(MapFeature? path) {
    editing = path;
    direction = path == null ? PathDirection.both : pathDirection(path);
    reversePreview = false;
    draft = PathDraft(path?.rings.single ?? []);
    name.text = path?.name ?? 'Walkway ${paths.length + 1}';
    forwardCue.text = '${path?.properties['forward_start_cue'] ?? ''}';
    reverseCue.text = '${path?.properties['reverse_start_cue'] ?? ''}';
    forwardNote.text = '${path?.properties['forward_note'] ?? ''}';
    reverseNote.text = '${path?.properties['reverse_note'] ?? ''}';
    reviewed = path?.properties['reviewed'] == true;
    dirty = false;
    selected = null;
    mode = path == null ? PathEditMode.draw : PathEditMode.vertices;
  }

  Future<bool> discard() async {
    if (!dirty) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Discard unsaved path changes?'),
            content: const Text('The saved map will keep its previous paths.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep editing'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Discard changes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> leave() async {
    if (busy || !await discard() || !mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> switchPath(MapFeature? path) async {
    if (busy || !await discard() || !mounted) return;
    setState(() {
      load(path);
      status = path == null ? 'New path. Click to add points.' : 'Drag numbered handles to reshape this path. Changes require a new walkability review.';
    });
    focus.requestFocus();
  }

  void geometry(List<GeoPoint> next, [String? hint]) {
    setState(() {
      draft.commit(next);
      dirty = true;
      reviewed = false;
      if (selected != null && selected! >= next.length) selected = null;
      status = hint ?? 'Unsaved path changes';
    });
  }

  void history(bool redo) {
    setState(() {
      if (redo) {
        draft.redo();
      } else {
        draft.undo();
      }
      selected = null;
      reviewed = false;
      dirty = true;
      status = 'Unsaved path changes';
    });
  }

  void removeVertex() {
    if (selected == null || busy) return;
    final next = List.of(draft.points)..removeAt(selected!);
    geometry(next);
    setState(() => selected = null);
  }

  Future<void> deletePath(MapFeature path) async {
    if (busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${path.name}?'),
        content: Text(
          'Remove this saved path from the project and future exports?${dirty && editing?.id == path.id ? ' Unsaved changes to this path will also be discarded.' : ''} Landmarks, panoramas and other paths stay in place.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete path'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => busy = true);
    try {
      await widget.store.deletePath(widget.project, path);
      if (mounted) {
        setState(() {
          if (editing?.id == path.id) load(null);
          status = 'Deleted ${path.name}';
        });
      }
    } catch (e) {
      if (mounted) setState(() => status = 'Could not delete path: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save() async {
    if (busy || !dirty || draft.problem != null || name.text.trim().isEmpty) {
      return;
    }
    setState(() => busy = true);
    final oldAnnotations = List.of(widget.project.annotations);
    try {
      final old = editing;
      final editable =
          old != null && widget.project.annotations.any((a) => a.id == old.id);
      final feature = MapFeature(
        editable ? old.id : newId(),
        name.text.trim(),
        widget.floor,
        'LineString',
        [List.of(draft.points)],
        {
          ...?old?.properties,
          'type': 'path',
          'reviewed': reviewed,
          'travel_direction': direction.name,
          'oneway': direction != PathDirection.both,
          'forward_start_cue': forwardCue.text.trim(),
          'reverse_start_cue': reverseCue.text.trim(),
          'forward_note': forwardNote.text.trim(),
          'reverse_note': reverseNote.text.trim(),
          if (old != null && !editable) 'source_feature_id': old.id,
        },
      );
      final checked = MapData.parse(
        jsonEncode({
          'type': 'FeatureCollection',
          'features': [feature.toGeoJson()],
        }),
      ).features.single;
      widget.project.annotations.removeWhere((a) => a.id == checked.id);
      widget.project.annotations.add(checked);
      await widget.store.save(widget.project);
      if (mounted) {
        setState(() {
          load(checked);
          status =
              'Saved ${checked.name}. ${reviewed ? 'Reviewed for routing.' : 'Unreviewed; excluded from routing.'}';
        });
      }
    } catch (e) {
      widget.project.annotations
        ..clear()
        ..addAll(oldAnnotations);
      if (mounted) setState(() => status = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  KeyEventResult key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        busy ||
        FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }
    final control = HardwareKeyboard.instance.isControlPressed;
    if (control && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (draft.canUndo) history(false);
      return KeyEventResult.handled;
    }
    if (control && event.logicalKey == LogicalKeyboardKey.keyY) {
      if (draft.canRedo) history(true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      removeVertex();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      switchPath(editing);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      save();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    name.dispose();
    forwardCue.dispose();
    reverseCue.dispose();
    forwardNote.dispose();
    reverseNote.dispose();
    viewport.dispose();
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) leave();
    },
    child: Focus(
      autofocus: true,
      focusNode: focus,
      onKeyEvent: key,
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: leave),
          title: Text('Path editor · floor ${widget.floor}'),
          actions: [
            TextButton(
              onPressed: busy ? null : () => switchPath(editing),
              child: const Text('Cancel changes'),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed:
                    busy ||
                        !dirty ||
                        draft.problem != null ||
                        name.text.trim().isEmpty
                    ? null
                    : save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save path'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (busy) const LinearProgressIndicator(),
            Material(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<PathEditMode>(
                      segments: const [
                        ButtonSegment(
                          value: PathEditMode.draw,
                          icon: Icon(Icons.add_location_alt_outlined),
                          label: Text('Draw'),
                        ),
                        ButtonSegment(
                          value: PathEditMode.vertices,
                          icon: Icon(Icons.open_with),
                          label: Text('Move points'),
                        ),
                        ButtonSegment(
                          value: PathEditMode.insert,
                          icon: Icon(Icons.add),
                          label: Text('Insert point'),
                        ),
                        ButtonSegment(
                          value: PathEditMode.pan,
                          icon: Icon(Icons.pan_tool_outlined),
                          label: Text('Pan'),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: busy
                          ? null
                          : (value) => setState(() {
                              mode = value.single;
                              status = switch (mode) {
                                PathEditMode.draw => 'Click to append points. Drag to pan; scroll to zoom.',
                                PathEditMode.vertices => 'Drag numbered handles to move points. Click a handle, then Delete to remove it.',
                                PathEditMode.insert =>
                                  'Click a draft segment to insert a bend.',
                                PathEditMode.pan => 'Drag to pan; scroll to zoom. Drawing is paused.',
                              };
                            }),
                    ),
                    IconButton(
                      tooltip: 'Undo (Ctrl+Z)',
                      onPressed: busy || !draft.canUndo
                          ? null
                          : () => history(false),
                      icon: const Icon(Icons.undo),
                    ),
                    IconButton(
                      tooltip: 'Redo (Ctrl+Y)',
                      onPressed: busy || !draft.canRedo
                          ? null
                          : () => history(true),
                      icon: const Icon(Icons.redo),
                    ),
                    IconButton(
                      tooltip: 'Remove selected point (Delete)',
                      onPressed: busy || selected == null ? null : removeVertex,
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                    TextButton.icon(
                      onPressed: () => viewport.value = Matrix4.identity(),
                      icon: const Icon(Icons.fit_screen),
                      label: const Text('Fit map'),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final panel = SizedBox(width: 280, child: sidebar());
                  final canvas = PathCanvas(
                    features: features,
                    points: draft.points,
                    mode: mode,
                    viewport: viewport,
                    selected: selected,
                    direction: direction,
                    enabled: !busy,
                    onSelect: (i) => setState(() => selected = i),
                    onChange: geometry,
                    onFocus: focus.requestFocus,
                    onStatus: (text) => setState(() => status = text),
                  );
                  if (constraints.maxWidth < 760) {
                    return Column(
                      children: [
                        SizedBox(height: 320, child: sidebar()),
                        Expanded(child: canvas),
                      ],
                    );
                  }
                  return Row(
                    children: [
                      panel,
                      const VerticalDivider(width: 1),
                      Expanded(child: canvas),
                    ],
                  );
                },
              ),
            ),
            Container(
              width: double.infinity,
              color: Colors.indigo.shade50,
              padding: const EdgeInsets.all(12),
              child: Text(status),
            ),
          ],
        ),
      ),
    ),
  );
  Widget sidebar() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: OutlinedButton.icon(
          onPressed: busy ? null : () => switchPath(null),
          icon: const Icon(Icons.add),
          label: const Text('New path'),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Saved paths (${paths.length})',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      ),
      if (paths.isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 150),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final path in paths)
                ListTile(
                  dense: true,
                  selected: editing?.id == path.id,
                  leading: Icon(
                    path.properties['reviewed'] == true
                        ? Icons.check_circle_outline
                        : Icons.pending_outlined,
                  ),
                  title: Text(path.name),
                  subtitle: Text(switch (pathDirection(path)) {
                    PathDirection.both => 'Both directions',
                    PathDirection.forward => 'Start → Destination',
                    PathDirection.reverse => 'Destination → Start',
                  }),
                  trailing: IconButton(
                    tooltip: 'Delete path ${path.name}',
                    onPressed: busy ? null : () => deletePath(path),
                    icon: const Icon(Icons.delete_outline),
                  ),
                  onTap: busy ? null : () => switchPath(path),
                ),
            ],
          ),
        ),
      const Divider(),
      Expanded(child: details()),
    ],
  );
  Widget details() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      TextField(
        controller: name,
        key: const ValueKey('path-name'),
        enabled: !busy,
        decoration: const InputDecoration(labelText: 'Path name'),
        onChanged: (_) => setState(() => dirty = true),
      ),
      const SizedBox(height: 12),
      Text(
        '${draft.points.length} points · ${draft.metres.toStringAsFixed(1)} m',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (draft.problem != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(draft.problem!),
        ),
      const SizedBox(height: 12),
      DropdownButtonFormField<PathDirection>(
        key: ValueKey('path-direction-${editing?.id}-${direction.name}'),
        initialValue: direction,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Allowed travel direction',
        ),
        items: const [
          DropdownMenuItem(
            value: PathDirection.both,
            child: Text(
              'Both directions (default)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownMenuItem(
            value: PathDirection.forward,
            child: Text(
              'Start → Destination',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownMenuItem(
            value: PathDirection.reverse,
            child: Text(
              'Destination → Start',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        onChanged: busy
            ? null
            : (value) => setState(() {
                direction = value ?? PathDirection.both;
                dirty = true;
                reviewed = false;
              }),
      ),
      if (direction == PathDirection.both)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Preview Destination → Start'),
          value: reversePreview,
          onChanged: (value) => setState(() => reversePreview = value),
        ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: reviewed,
        onChanged: busy
            ? null
            : (value) => setState(() {
                reviewed = value ?? false;
                dirty = true;
              }),
        title: const Text('Walkability checked'),
        subtitle: const Text(
          'I checked this complete path, including bends and doorways.',
        ),
      ),
      const Text(
        'Snap rings show shared path vertices and landmark points. Connect at the same ring to make a junction. Crossing lines alone do not connect.',
      ),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Orientation and surroundings'),
        subtitle: const Text('Optional, mapper-verified wording'),
        children: [
          for (final field in [
            (forwardCue, 'Start orientation: S to D'),
            (reverseCue, 'Start orientation: D to S'),
            (forwardNote, 'Surroundings: S to D'),
            (reverseNote, 'Surroundings: D to S'),
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: field.$1,
                enabled: !busy,
                maxLength: 500,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: field.$2,
                  helperText: 'Describe stable, checked landmarks; avoid compass-only wording.',
                  helperMaxLines: 3,
                ),
                onChanged: (_) => setState(() {
                  dirty = true;
                  reviewed = false;
                }),
              ),
            ),
        ],
      ),
      if (draft.points.length >= 2)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(
            'Preview ${direction == PathDirection.reverse || (direction == PathDirection.both && reversePreview) ? 'D → S' : 'S → D'} (${drawingGuidance.steps.length} steps)',
          ),
          children: [
            for (final step in drawingGuidance.steps)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(routeIcon(step.action)),
                title: Text(step.title),
                subtitle: Text(step.instruction),
              ),
          ],
        ),
    ],
  );
}

class PathCanvas extends StatefulWidget {
  const PathCanvas({
    super.key,
    required this.features,
    required this.points,
    required this.mode,
    required this.viewport,
    required this.selected,
    required this.onSelect,
    required this.onChange,
    required this.onStatus,
    required this.onFocus,
    this.enabled = true,
    this.direction = PathDirection.both,
  });
  final List<MapFeature> features;
  final List<GeoPoint> points;
  final PathEditMode mode;
  final TransformationController viewport;
  final int? selected;
  final bool enabled;
  final PathDirection direction;
  final void Function(int?) onSelect;
  final void Function(List<GeoPoint>, [String?]) onChange;
  final void Function(String) onStatus;
  final VoidCallback onFocus;
  @override
  State<PathCanvas> createState() => _PathCanvasState();
}

class _PathCanvasState extends State<PathCanvas> {
  GeoPoint? hover;
  List<GeoPoint>? dragging;
  int? dragIndex;
  late MapTransform transform;
  double get zoom => widget.viewport.value.getMaxScaleOnAxis();
  int? handle(Offset tap) {
    final points = dragging ?? widget.points;
    var best = 16 / zoom;
    int? result;
    for (var i = 0; i < points.length; i++) {
      final d = (transform.screen(points[i]) - tap).distance;
      if (d < best) {
        best = d;
        result = i;
      }
    }
    return result;
  }

  GeoPoint snap(Offset tap, {int? skip}) {
    var best = 14 / zoom;
    GeoPoint? candidate;
    for (final feature in widget.features.where(
      (f) => f.isPoint || f.type == 'LineString',
    )) {
      for (final point in feature.points) {
        // Moving an old handle should not snap back to its own saved position.
        if (skip != null &&
            point.lon == widget.points[skip].lon &&
            point.lat == widget.points[skip].lat) {
          continue;
        }
        final d = (transform.screen(point) - tap).distance;
        if (d < best) {
          best = d;
          candidate = point;
        }
      }
    }
    return candidate ?? transform.geo(tap);
  }

  void tap(Offset tap) {
    if (!widget.enabled) return;
    widget.onFocus();
    switch (widget.mode) {
      case PathEditMode.pan:
        break;
      case PathEditMode.vertices:
        widget.onSelect(handle(tap));
        break;
      case PathEditMode.draw:
        final point = snap(tap);
        if (widget.points.isNotEmpty &&
            LocalFrame(widget.points.last)
                    .project(point)
                    .distance(const XY(0, 0)) <
                .02) {
          widget.onStatus(
            'That point is already the last vertex. Click a different position.',
          );
          return;
        }
        widget.onChange(
          [...widget.points, point],
          'Point ${widget.points.length + 1} placed. Rings indicate exact snap positions.',
        );
        break;
      case PathEditMode.insert:
        var best = 20 / zoom;
        int? insert;
        for (var i = 1; i < widget.points.length; i++) {
          final a = transform.screen(widget.points[i - 1]),
              b = transform.screen(widget.points[i]),
              d = b - a;
          final square = d.dx * d.dx + d.dy * d.dy;
          if (square == 0) continue;
          final r = tap - a;
          final fraction = ((r.dx * d.dx + r.dy * d.dy) / square).clamp(
            0.0,
            1.0,
          );
          final distance = (tap - (a + d * fraction)).distance;
          if (distance < best) {
            best = distance;
            insert = i;
          }
        }
        if (insert == null) {
          widget.onStatus('Click close to a draft segment to add a bend.');
          return;
        }
        final next = List.of(widget.points)..insert(insert, snap(tap));
        widget.onChange(next, 'Bend inserted. Drag it with Move points.');
        widget.onSelect(insert);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      transform = MapTransform(widget.features, [], size);
      return ClipRect(
        child: InteractiveViewer(
          transformationController: widget.viewport,
          minScale: .5,
          maxScale: 20,
          boundaryMargin: const EdgeInsets.all(400),
          panEnabled: widget.enabled && widget.mode != PathEditMode.vertices,
          child: MouseRegion(
            cursor: widget.mode == PathEditMode.pan
                ? SystemMouseCursors.grab
                : SystemMouseCursors.precise,
            onHover: (event) =>
                setState(() => hover = snap(event.localPosition)),
            onExit: (_) => setState(() => hover = null),
            child: GestureDetector(
              dragStartBehavior: DragStartBehavior.down,
              behavior: HitTestBehavior.opaque,
              onTapUp: (event) => tap(event.localPosition),
              onPanStart:
                  widget.mode != PathEditMode.vertices || !widget.enabled
                  ? null
                  : (event) {
                      widget.onFocus();
                      dragIndex = handle(event.localPosition);
                      widget.onSelect(dragIndex);
                      if (dragIndex != null) {
                        setState(() => dragging = List.of(widget.points));
                      }
                    },
              onPanUpdate:
                  widget.mode != PathEditMode.vertices || !widget.enabled
                  ? null
                  : (event) {
                      if (dragIndex != null) {
                        setState(
                          () => dragging![dragIndex!] = snap(
                            event.localPosition,
                            skip: dragIndex,
                          ),
                        );
                      }
                    },
              onPanEnd: widget.mode != PathEditMode.vertices || !widget.enabled
                  ? null
                  : (_) {
                      if (dragging != null) {
                        widget.onChange(
                          dragging!,
                          'Point moved. Review the changed path before routing.',
                        );
                      }
                      setState(() {
                        dragging = null;
                        dragIndex = null;
                      });
                    },
              onPanCancel: () => setState(() {
                dragging = null;
                dragIndex = null;
              }),
              child: SizedBox.fromSize(
                size: size,
                child: CustomPaint(
                  key: const ValueKey('path-editor-canvas'),
                  painter: FloorPainter(
                    transform,
                    widget.features,
                    [],
                    [],
                    1,
                    [],
                    null,
                    null,
                  ),
                  foregroundPainter: _PathOverlay(
                    transform,
                    widget.features,
                    dragging ?? widget.points,
                    widget.selected,
                    widget.mode == PathEditMode.draw ? hover : null,
                    zoom,
                    widget.direction,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _PathOverlay extends CustomPainter {
  _PathOverlay(
    this.transform,
    this.features,
    this.points,
    this.selected,
    this.hover,
    this.zoom,
    this.direction,
  );
  final PathDirection direction;
  final MapTransform transform;
  final List<MapFeature> features;
  final List<GeoPoint> points;
  final int? selected;
  final GeoPoint? hover;
  final double zoom;
  @override
  void paint(Canvas canvas, Size size) {
    for (final feature in features.where(
      (f) => f.isPoint || f.type == 'LineString',
    )) {
      for (final point in feature.points) {
        canvas.drawCircle(
          transform.screen(point),
          7 / zoom,
          Paint()
            ..color = Colors.indigo
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 / zoom,
        );
      }
    }
    for (var i = 1; i < points.length; i++) {
      canvas.drawLine(
        transform.screen(points[i - 1]),
        transform.screen(points[i]),
        Paint()
          ..color = Colors.deepOrange
          ..strokeWidth = 4 / zoom,
      );
    }
    for (var i = 1; i < points.length; i++) {
      drawRouteArrows(
        canvas,
        transform.screen(
          points[direction == PathDirection.reverse ? i : i - 1],
        ),
        transform.screen(
          points[direction == PathDirection.reverse ? i - 1 : i],
        ),
        color: Colors.white,
        zoom: zoom,
        bothDirections: direction == PathDirection.both,
      );
    }
    if (points.isNotEmpty) {
      drawRouteBadge(
        canvas,
        transform.screen(points.first) + Offset(0, -26 / zoom),
        'S',
        Colors.teal,
        zoom: zoom,
      );
    }
    if (points.length > 1) {
      drawRouteBadge(
        canvas,
        transform.screen(points.last) + Offset(0, -26 / zoom),
        'D',
        Colors.red.shade700,
        zoom: zoom,
      );
    }
    if (hover != null && points.isNotEmpty) {
      final a = transform.screen(points.last),
          b = transform.screen(hover!),
          delta = b - a;
      final length = delta.distance;
      for (var d = 0.0; d < length; d += 12 / zoom) {
        canvas.drawLine(
          a + delta * (d / math.max(length, 1)),
          a + delta * (math.min(d + 6 / zoom, length) / math.max(length, 1)),
          Paint()
            ..color = Colors.deepOrange.withValues(alpha: .6)
            ..strokeWidth = 2 / zoom,
        );
      }
      final metres = LocalFrame(points.last)
          .project(hover!)
          .distance(const XY(0, 0));
      final text = TextPainter(
        text: TextSpan(
          text: '${metres.toStringAsFixed(1)} m',
          style: TextStyle(
            color: Colors.deepOrange.shade900,
            fontSize: 13 / zoom,
            backgroundColor: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, (a + b) / 2);
    }
    for (var i = 0; i < points.length; i++) {
      final position = transform.screen(points[i]);
      final color = i == selected
          ? Colors.deepOrange
          : i == 0
          ? Colors.teal
          : Colors.indigo;
      canvas.drawCircle(position, 11 / zoom, Paint()..color = Colors.white);
      canvas.drawCircle(
        position,
        11 / zoom,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2 / zoom,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: color,
            fontSize: 12 / zoom,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, position - Offset(text.width / 2, text.height / 2));
    }
  }

  @override
  bool shouldRepaint(_PathOverlay oldDelegate) => true;
}
