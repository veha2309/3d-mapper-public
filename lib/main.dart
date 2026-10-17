import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'domain.dart';
import 'map_view.dart';
import 'floor_3d_view.dart';
import 'panorama_view.dart';
import 'storage.dart';
import 'recognition_page.dart';
import 'test_logs.dart';
import 'test_logs_page.dart';
import 'landmark_admin_page.dart';
import 'navigation_page.dart';
import 'path_editor.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  runApp(
    MapperApp(
      store: ProjectStore(Directory(path.join(support.path, 'projects'))),
    ),
  );
}

class MapperApp extends StatelessWidget {
  const MapperApp({super.key, required this.store, this.authoring});
  final ProjectStore store;
  final bool? authoring;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '3D Mapper',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff1760be)),
      scaffoldBackgroundColor: const Color(0xfff7f9fc),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
    ),
    home: Workspace(store: store, authoring: authoring ?? Platform.isWindows),
  );
}

enum MapTool { select, centre, landmark, polygon, moveCentre, moveLandmark }

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.store, required this.authoring});
  final ProjectStore store;
  final bool authoring;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  MapperProject? project;
  List<({String id, String name})> projects = [];
  String floor = '0';
  String? selectedCentre, selectedFeature;
  MapTool tool = MapTool.select;
  final draft = <GeoPoint>[];
  List<GeoPoint> preview = [];
  GridSettings? previewSettings;
  MapFeature? editingPolygon;
  bool busy = false;
  bool show3D = false;
  bool get viewing3D =>
      show3D && tool == MapTool.select && previewSettings == null;
  String status = 'Ready';
  ProjectStore get store => widget.store;
  CaptureCentre? get centre =>
      project?.centres.where((c) => c.id == selectedCentre).firstOrNull;
  MapFeature? get feature =>
      project?.features.where((f) => f.id == selectedFeature).firstOrNull;
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final items = await store.list();
      if (mounted) setState(() => projects = items);
    } catch (e) {
      if (mounted) setState(() => status = 'Cannot read projects: $e');
    }
  }

  void message(String text) {
    if (!mounted) return;
    setState(() => status = text);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      message('$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> change(void Function(MapperProject p) mutate) async {
    final original = MapperProject.fromJson(project!.toJson(), project!.source);
    try {
      mutate(project!);
      await store.save(project!);
      if (mounted) {
        setState(() {
          status = 'Saved locally';
        });
      }
    } catch (_) {
      if (mounted) setState(() => project = original);
      rethrow;
    }
  }

  void openProject(MapperProject p) {
    setState(() {
      project = p;
      floor = p.floors.first;
      selectedCentre = null;
      selectedFeature = null;
      tool = MapTool.select;
      show3D = false;
      draft.clear();
      preview = [];
      editingPolygon = null;
      previewSettings = null;
      status = p.sourceData.warnings.isEmpty
          ? 'Project opened · stored locally'
          : '${p.sourceData.warnings.length} map warnings — review Import details';
    });
  }

  Future<String?> prompt(
    String title, {
    String initial = '',
    String? helper,
  }) async {
    final controller = TextEditingController(text: initial);
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 400,
            child: TextField(
              controller: controller,
              autofocus: true,
              maxLength: 160,
              decoration: InputDecoration(helperText: helper, errorText: error),
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  Navigator.pop(context, value.trim());
                }
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isEmpty) {
                  setDialogState(() => error = 'Enter a value');
                  return;
                }
                Navigator.pop(context, controller.text.trim());
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    // The dialog route may still be animating; its text controller is disposed after dismissal.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    return result;
  }

  Future<bool> confirm(String title, String description) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(description),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm'),
            ),
          ],
        ),
      ) ??
      false;
  Future<Uint8List?> pick(
    List<String> extensions, {
    int limit = ProjectStore.maxAssetBytes,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: extensions,
    );
    if (result == null) return null;
    final file = result.files.single;
    if (file.size > limit) {
      throw FormatException(
        'Selected file exceeds ${(limit / 1024 / 1024).round()} MB',
      );
    }
    return file.bytes ?? await File(file.path!).readAsBytes();
  }

  Future<void> importMap() => run(() async {
    final bytes = await pick([
      'json',
      'geojson',
    ], limit: ProjectStore.maxMapBytes);
    if (bytes == null || !mounted) return;
    final source = utf8.decode(bytes);
    MapData.parse(source);
    final name = await prompt(
      'New project name',
      initial: 'Office capture project',
    );
    if (name == null) return;
    final p = await store.create(name, source);
    if (!mounted) return;
    openProject(p);
    await refresh();
    if (p.sourceData.warnings.isNotEmpty) await showImportDetails();
  });
  Future<void> importBundle() => run(() async {
    // Android providers can omit unknown extension filters, so use All files there.
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null) return;
    final file = result.files.single;
    if (file.size > ProjectStore.maxBundleBytes) {
      throw const FormatException('Bundle exceeds 512 MB');
    }
    final p = await store.importBundle(
      file.bytes ?? await File(file.path!).readAsBytes(),
    );
    if (mounted) openProject(p);
    await refresh();
  });
  Future<void> exportBundle() => run(() async {
    final bytes = await store.exportBundle(project!);
    final output = await FilePicker.platform.saveFile(
      dialogTitle: 'Export portable mapper project',
      fileName:
          '${project!.name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')}.mapper',
      type: FileType.custom,
      allowedExtensions: ['mapper'],
      bytes: bytes,
    );
    if (output != null) {
      if (Platform.isWindows) {
        await File(output).writeAsBytes(bytes, flush: true);
      }
      message('Exported portable project');
    }
  });
  Future<void> showImportDetails() async {
    final p = project!;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import details'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              '${p.sourceData.features.length} supported source features.\nOriginal source retained without changes.\n\n${p.sourceData.warnings.isEmpty ? 'No warnings.' : p.sourceData.warnings.join('\n\n')}',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void chooseTool(MapTool value) => setState(() {
    tool = value;
    show3D = false;
    draft.clear();
    editingPolygon = null;
    preview = [];
    previewSettings = null;
  });
  Future<void> mapTap(
    GeoPoint point,
    String? centreId,
    String? featureId,
  ) async {
    if (busy) return;
    if (!widget.authoring || tool == MapTool.select) {
      setState(() {
        selectedCentre = centreId;
        selectedFeature = centreId == null ? featureId : null;
      });
      return;
    }
    if (tool == MapTool.polygon) {
      setState(() => draft.add(point));
      return;
    }
    await run(() async {
      if (tool == MapTool.centre) {
        final name = await prompt(
          'Capture centre name',
          initial: 'C${project!.centres.length + 1}',
        );
        if (name == null) return;
        final c = CaptureCentre(newId(), name, floor, point);
        await change((p) => p.centres.add(c));
        if (mounted) {
          setState(() {
            selectedCentre = c.id;
            selectedFeature = null;
            tool = MapTool.select;
          });
        }
      } else if (tool == MapTool.moveCentre && centre != null) {
        await change((_) => centre!.position = point);
        if (mounted) setState(() => tool = MapTool.select);
      } else if (tool == MapTool.moveLandmark && feature != null) {
        final f = feature!;
        await saveAnnotation(f, f.name, [
          [point],
        ]);
        if (mounted) setState(() => tool = MapTool.select);
      } else if (tool == MapTool.landmark) {
        final name = await prompt('Landmark name');
        if (name == null) return;
        final f = MapFeature(
          newId(),
          name,
          floor,
          'Point',
          [
            [point],
          ],
          {'type': 'Landmark'},
        );
        await change((p) => p.annotations.add(f));
        if (mounted) {
          setState(() {
            selectedCentre = null;
            selectedFeature = f.id;
            tool = MapTool.select;
          });
        }
      }
    });
  }

  Future<void> saveAnnotation(
    MapFeature f,
    String name,
    List<List<GeoPoint>> rings,
  ) async {
    final editable = project!.annotations.any((a) => a.id == f.id);
    final annotation = MapFeature(
      editable ? f.id : newId(),
      name,
      f.floor,
      f.type,
      rings,
      {...f.properties, if (!editable) 'source_feature_id': f.id},
    );
    await change((p) {
      p.annotations.removeWhere((a) => a.id == annotation.id);
      p.annotations.add(annotation);
    });
    if (mounted) setState(() => selectedFeature = annotation.id);
  }

  Future<void> openPathEditor() async {
    if (busy || project == null) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PathEditorPage(
          project: project!,
          store: store,
          floor: floor,
          initialPath: feature?.type == 'LineString' ? feature : null,
        ),
      ),
    );
    if (mounted) {
      setState(() {
        selectedFeature = null;
        chooseTool(MapTool.select);
        status = 'Path editor closed';
      });
    }
  }

  Future<void> finishPolygon() => run(() async {
    if (draft.length < 3) {
      throw const FormatException('Place at least three polygon vertices');
    }
    final previous = editingPolygon;
    final name = await prompt(
      'Polygon name',
      initial: previous?.name ?? 'New area',
    );
    if (name == null) return;
    final rings = [
      [...draft, draft.first],
    ];
    final candidate = MapFeature(
      previous?.id ?? newId(),
      name,
      floor,
      'Polygon',
      rings,
      previous?.properties ?? {'type': 'Area'},
    );
    final validation = MapData.parse(
      jsonEncode({
        'type': 'FeatureCollection',
        'features': [candidate.toGeoJson()],
      }),
    );
    if (validation.warnings.isNotEmpty) {
      throw const FormatException('Invalid polygon');
    }
    if (previous == null) {
      await change((p) => p.annotations.add(candidate));
    } else {
      await saveAnnotation(previous, name, rings);
    }
    if (mounted) {
      setState(() {
        draft.clear();
        editingPolygon = null;
        tool = MapTool.select;
      });
    }
  });
  Future<void> grid() => run(() async {
    final text = await prompt(
      'Hex grid spacing in metres',
      initial: '2',
      helper: 'Distance between neighbouring centres; 0.5–100 m',
    );
    if (text == null) return;
    final spacing = double.tryParse(text);
    if (spacing == null) {
      throw const FormatException('Enter a spacing in metres');
    }
    final floorFeatures = project!.features
        .where((f) => f.floor == floor)
        .toList();
    final settings = GridSettings(
      floor,
      spacing,
      floorFeatures.first.points.first,
    );
    final points = generateGrid(floorFeatures, settings);
    if (mounted) {
      setState(() {
        preview = points;
        previewSettings = settings;
        tool = MapTool.select;
        draft.clear();
        editingPolygon = null;
      });
    }
    if (points.isEmpty) {
      message('No centres fit. Reduce spacing or place centres manually.');
    }
  });
  Future<void> acceptGrid() => run(() async {
    final settings = previewSettings!;
    final frame = LocalFrame(settings.origin);
    var count = 0;
    await change((p) {
      for (final position in preview) {
        if (p.centres.any(
          (c) =>
              c.floor == floor &&
              frame.project(c.position).distance(frame.project(position)) < .1,
        )) {
          continue;
        }
        p.centres.add(
          CaptureCentre(newId(), 'C${p.centres.length + 1}', floor, position),
        );
        count++;
      }
      p.grids.add(settings);
    });
    if (mounted) {
      setState(() {
        preview = [];
        previewSettings = null;
      });
    }
    message(
      'Added $count centres. Review every centre for walkability and visibility.',
    );
  });
  Future<void> attach({Panorama? replace}) => run(() async {
    final c = centre!;
    final bytes = await pick(['jpg', 'jpeg']);
    if (bytes == null) return;
    await store.attach(project!, c, bytes, replace: replace);
    if (mounted) setState(() => status = 'Panorama copied into local project');
  });
  Future<void> renameSelection() => run(() async {
    if (centre != null) {
      final name = await prompt('Capture centre name', initial: centre!.name);
      if (name != null) await change((_) => centre!.name = name);
    } else if (feature != null) {
      final f = feature!;
      final name = await prompt('Annotation name', initial: f.name);
      if (name != null) await saveAnnotation(f, name, f.rings);
    }
  });
  Future<void> deleteSelection() => run(() async {
    final c = centre, f = feature;
    if (c == null && f == null) return;
    final editable = f != null && project!.annotations.any((a) => a.id == f.id);
    if (c == null && !editable) return;
    if (!await confirm(
      'Delete ${c?.name ?? f!.name}?',
      c == null
          ? 'The editable annotation will be removed. Any original source feature becomes visible again.'
          : 'The centre and its panorama associations will be removed from this project.',
    )) {
      return;
    }
    await change((p) {
      if (c != null) p.centres.removeWhere((item) => item.id == c.id);
      if (f != null) p.annotations.removeWhere((item) => item.id == f.id);
    });
    if (mounted) {
      setState(() {
        selectedCentre = null;
        selectedFeature = null;
        tool = MapTool.select;
      });
    }
  });
  Widget action(String label, IconData icon, VoidCallback onPressed) => Padding(
    padding: const EdgeInsets.only(right: 6, bottom: 6),
    child: OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('3D Mapper'),
      actions: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Chip(
            label: Text(
              widget.authoring ? 'Windows · Author' : 'Android · Review',
            ),
          ),
        ),
        if (project != null)
          IconButton(
            tooltip: 'Project library',
            onPressed: busy ? null : () => setState(() => project = null),
            icon: const Icon(Icons.folder_open),
          ),
      ],
    ),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: AbsorbPointer(
            absorbing: busy,
            child: project == null ? library() : editor(),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          color: const Color(0xffe6edf5),
          child: Text(status, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ],
    ),
  );
  Future<void> deleteLocalProject(String id, String name) => run(() async {
    if (!await confirm(
      'Delete project “$name”?',
      'Delete this local project, its annotations, and attached photos from this device? Export it first if you need a backup. Exported .mapper files and saved test logs are kept.',
    )) {
      return;
    }
    await store.deleteProject(id);
    if (project?.id == id && mounted) setState(() => project = null);
    await refresh();
    message('Deleted local project: $name');
  });
  Widget library() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 850),
      child: ListView(
        padding: const EdgeInsets.all(28),
        children: [
          const Icon(Icons.view_in_ar, size: 64, color: Color(0xff1760be)),
          const SizedBox(height: 16),
          Text(
            'Map the place. Organize every view.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 12),
          Text(
            widget.authoring
                ? 'Import your georeferenced map, plan capture centres, and attach Insta360 X4 panoramas. Everything stays on this device.'
                : 'Import a .mapper project from Windows to review its map, capture centres, and 360° panoramas offline.',
          ),
          const SizedBox(height: 24),
          Wrap(
            children: [
              if (widget.authoring)
                action('Import map', Icons.add_location_alt, importMap),
              action('Import .mapper project', Icons.file_open, importBundle),
              if (!widget.authoring)
                action(
                  'Test logs',
                  Icons.receipt_long,
                  () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          TestLogsPage(directory: testLogDirectory(store.root)),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Local projects', style: Theme.of(context).textTheme.titleLarge),
          if (projects.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No projects yet. Import a project to get started.'),
            ),
          ...projects.map(
            (p) => Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(p.name),
                subtitle: Text(p.id),
                trailing: IconButton(
                  tooltip: 'Delete project ${p.name}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => deleteLocalProject(p.id, p.name),
                ),
                onTap: () => run(() async {
                  final opened = await store.open(p.id);
                  if (mounted) openProject(opened);
                }),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Windows prepares labeled panorama references. Android tests them with its camera. 3D reconstruction and phone localization are future milestones.',
          ),
        ],
      ),
    ),
  );
  Widget editor() => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 850;
      final map = Column(
        children: [
          toolbar(),
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: viewing3D
                      ? Floor3DView(
                          key: ValueKey('3d/${project!.id}/$floor'),
                          features: project!.features
                              .where((f) => f.floor == floor)
                              .toList(),
                          centres: project!.centres
                              .where((c) => c.floor == floor)
                              .toList(),
                          selectedCentre: selectedCentre,
                          selectedFeature: selectedFeature,
                          onSelect: (centreId, featureId) {
                            if (busy) return;
                            setState(() {
                              selectedCentre = centreId;
                              selectedFeature = featureId;
                            });
                          },
                        )
                      : FloorMap(
                          key: ValueKey('${project!.id}/$floor'),
                          features: project!.features
                              .where((f) => f.floor == floor)
                              .toList(),
                          centres: project!.centres
                              .where((c) => c.floor == floor)
                              .toList(),
                          preview: preview,
                          spacing: previewSettings?.spacing ?? 2,
                          draft: draft,
                          selectedCentre: selectedCentre,
                          selectedFeature: selectedFeature,
                          onTap: mapTap,
                        ),
                ),
                if (!viewing3D)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 8,
                    child: IgnorePointer(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(toolHint),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
      if (narrow) {
        return Column(
          children: [
            Expanded(child: map),
            SizedBox(height: constraints.maxHeight * .38, child: inspector()),
          ],
        );
      }
      return Row(
        children: [
          Expanded(child: map),
          SizedBox(width: 340, child: inspector()),
        ],
      );
    },
  );
  String get toolHint {
    if (previewSettings != null) {
      return '${preview.length} suggested centres · review furniture and accessibility before accepting';
    }
    return switch (tool) {
      MapTool.select =>
        'Select a centre or landmark · drag to pan · pinch or scroll to zoom',
      MapTool.centre => 'Click a walkable position to add a capture centre',
      MapTool.landmark => 'Click to add a named landmark',
      MapTool.polygon => 'Click polygon vertices, then Finish polygon',
      MapTool.moveCentre => 'Click the new capture-centre position',
      MapTool.moveLandmark => 'Click the new landmark position',
    };
  }

  Widget toolbar() => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
    color: Colors.white,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                project!.name,
                style: Theme.of(context).textTheme.titleMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Text('Floor '),
            DropdownButton<String>(
              value: floor,
              items: project!.floors
                  .map((f) => DropdownMenuItem(value: f, child: Text(f)))
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    final keep3D = viewing3D;
                    floor = value;
                    selectedCentre = null;
                    selectedFeature = null;
                    chooseTool(MapTool.select);
                    show3D = keep3D;
                  });
                }
              },
            ),
          ],
        ),
        if (widget.authoring)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('2D map'),
                  icon: Icon(Icons.map_outlined),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('3D view'),
                  icon: Icon(Icons.view_in_ar),
                ),
              ],
              selected: {viewing3D},
              onSelectionChanged: draft.isNotEmpty || previewSettings != null
                  ? null
                  : (values) => setState(() {
                      show3D = values.single;
                      tool = MapTool.select;
                      editingPolygon = null;
                    }),
            ),
          ),
        if (widget.authoring)
          Wrap(
            children: [
              action(
                'Select',
                Icons.near_me_outlined,
                () => chooseTool(MapTool.select),
              ),
              action(
                'Centre',
                Icons.add_location_alt_outlined,
                () => chooseTool(MapTool.centre),
              ),
              action(
                'Landmark',
                Icons.place_outlined,
                () => chooseTool(MapTool.landmark),
              ),
              action(
                'Polygon',
                Icons.polyline_outlined,
                () => chooseTool(MapTool.polygon),
              ),
              action('Hex grid', Icons.hexagon_outlined, grid),
              action('Path editor', Icons.route, openPathEditor),
              action('Export', Icons.ios_share, exportBundle),
            ],
          ),
        TextButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => NavigationPage(
                project: project!,
                store: store,
                floor: floor,
                onProjectChanged: (updated) =>
                    setState(() => project = updated),
              ),
            ),
          ),
          icon: const Icon(Icons.route),
          label: const Text('Route preview'),
        ),
        if (!widget.authoring)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RecognitionPage(
                    project: project!,
                    store: store,
                    floor: floor,
                  ),
                ),
              ),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Test camera recognition'),
            ),
          ),
        if (!widget.authoring)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: OutlinedButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => LandmarkAdminPage(
                    project: project!,
                    store: store,
                    floor: floor,
                    onExport: exportBundle,
                  ),
                ),
              ),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Admin: landmark photos'),
            ),
          ),
        if (tool == MapTool.polygon)
          Wrap(
            children: [
              action(
                'Finish polygon (${draft.length})',
                Icons.check,
                finishPolygon,
              ),
              action(
                'Undo vertex',
                Icons.undo,
                () => setState(() {
                  if (draft.isNotEmpty) draft.removeLast();
                }),
              ),
              action('Cancel', Icons.close, () => chooseTool(MapTool.select)),
            ],
          ),
        if (previewSettings != null)
          Wrap(
            children: [
              action(
                'Accept ${preview.length} centres',
                Icons.check,
                acceptGrid,
              ),
              action(
                'Discard preview',
                Icons.close,
                () => setState(() {
                  preview = [];
                  previewSettings = null;
                }),
              ),
            ],
          ),
      ],
    ),
  );
  Widget inspector() {
    final c = centre, f = feature;
    return Material(
      color: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            c != null
                ? 'Capture centre'
                : f != null
                ? 'Map annotation'
                : 'Capture project',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (c == null && f == null) ...[
            Text(
              '${project!.centres.where((c) => c.floor == floor).length} capture centres on floor $floor',
            ),
            const SizedBox(height: 8),
            const Text(
              'Orange: needs panorama. Blue: panorama attached. Grid suggestions require a walkability review.',
            ),
          ],
          if (c != null) ...[
            Text(c.name, style: Theme.of(context).textTheme.titleMedium),
            SelectableText(
              'Longitude ${c.position.lon.toStringAsFixed(8)}\nLatitude ${c.position.lat.toStringAsFixed(8)}\nFloor ${c.floor}',
            ),
            if (widget.authoring)
              Wrap(
                children: [
                  action('Rename', Icons.edit, renameSelection),
                  action(
                    'Move',
                    Icons.open_with,
                    () => setState(() {
                      tool = MapTool.moveCentre;
                      draft.clear();
                      preview = [];
                      previewSettings = null;
                    }),
                  ),
                  action('Delete', Icons.delete_outline, deleteSelection),
                  action(
                    'Attach 360° JPG',
                    Icons.add_photo_alternate_outlined,
                    attach,
                  ),
                ],
              ),
            if (c.panoramas.isEmpty)
              const Text(
                'No panorama attached. Use a full, stitched 2:1 JPG from Insta360 Studio.',
              ),
            ...c.panoramas.asMap().entries.map((entry) {
              final panorama = entry.value;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('360° view ${entry.key + 1}'),
                      Text(
                        'Heading offset ${panorama.heading.toStringAsFixed(1)}° from north',
                      ),
                      Wrap(
                        children: [
                          action(
                            'Open',
                            Icons.threesixty,
                            () => Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => PanoramaView(
                                  file: store.asset(project!, panorama),
                                  heading: panorama.heading,
                                  panorama: panorama,
                                  supportingPhotoFile: (photo) =>
                                      store.photoOriginal(project!, photo),
                                  onAddPhoto: !widget.authoring
                                      ? null
                                      : (label, bytes) async {
                                          await store.addSupportingPhoto(
                                            project!,
                                            label,
                                            bytes,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                  onRemovePhoto: !widget.authoring
                                      ? null
                                      : (label, photo) async {
                                          final index = label.photos.indexOf(
                                            photo,
                                          );
                                          label.photos.remove(photo);
                                          try {
                                            await store.save(project!);
                                          } catch (_) {
                                            label.photos.insert(index, photo);
                                            rethrow;
                                          }
                                          if (mounted) setState(() {});
                                        },
                                  landmarks: project!.features
                                      .where((f) => f.floor == c.floor)
                                      .toList(),
                                  onAddLabel: !widget.authoring
                                      ? null
                                      : (
                                          name,
                                          direction,
                                          bytes,
                                          featureId,
                                        ) async {
                                          await store.addLabel(
                                            project!,
                                            panorama,
                                            name,
                                            direction.yaw,
                                            direction.pitch,
                                            bytes,
                                            featureId: featureId,
                                          );
                                          if (mounted) setState(() {});
                                        },
                                  onEditLabel: !widget.authoring
                                      ? null
                                      : (label, name) async {
                                          final oldName = label.name;
                                          final index = panorama.labels.indexOf(
                                            label,
                                          );
                                          if (name == null) {
                                            panorama.labels.remove(label);
                                          } else {
                                            label.name = name;
                                          }
                                          try {
                                            await store.save(project!);
                                          } catch (_) {
                                            if (name == null) {
                                              panorama.labels.insert(
                                                index,
                                                label,
                                              );
                                            } else {
                                              label.name = oldName;
                                            }
                                            rethrow;
                                          }
                                          if (mounted) setState(() {});
                                        },
                                ),
                              ),
                            ),
                          ),
                          if (widget.authoring) ...[
                            action(
                              'Heading',
                              Icons.explore_outlined,
                              () => run(() async {
                                final text = await prompt(
                                  'Heading offset from north (degrees)',
                                  initial: panorama.heading.toStringAsFixed(1),
                                  helper: 'Bearing of the initial panorama view; clockwise from north',
                                );
                                if (text == null) return;
                                final value = double.tryParse(text);
                                if (value == null || !value.isFinite) {
                                  throw const FormatException(
                                    'Enter a finite heading in degrees',
                                  );
                                }
                                await change(
                                  (_) => panorama.heading = value % 360,
                                );
                              }),
                            ),
                            action(
                              'Replace',
                              Icons.change_circle_outlined,
                              () => attach(replace: panorama),
                            ),
                            action(
                              'Remove',
                              Icons.remove_circle_outline,
                              () => run(() async {
                                if (await confirm(
                                  'Remove panorama?',
                                  'This view will no longer be included in exported projects.',
                                )) {
                                  await change(
                                    (_) => c.panoramas.remove(panorama),
                                  );
                                }
                              }),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
          if (f != null) ...[
            Text(f.name, style: Theme.of(context).textTheme.titleMedium),
            Text('${f.type} · floor ${f.floor}'),
            if (widget.authoring)
              Wrap(
                children: [
                  action('Rename', Icons.edit, renameSelection),
                  if (f.type == 'LineString')
                    action('Edit path', Icons.route, openPathEditor),
                  if (f.type == 'LineString')
                    action(
                      f.properties['reviewed'] == true
                          ? 'Revoke path review'
                          : 'Review path',
                      Icons.fact_check,
                      () => run(() async {
                        final reviewed = f.properties['reviewed'] != true;
                        if (reviewed &&
                            !await confirm(
                              'Review walkable path?',
                              'Confirm this line follows the physically checked walkway, including its bends and doorways, avoiding stairs and furniture.',
                            )) {
                          return;
                        }
                        final updated = MapFeature(
                          f.id,
                          f.name,
                          f.floor,
                          f.type,
                          f.rings,
                          {...f.properties, 'reviewed': reviewed},
                        );
                        await saveAnnotation(
                          updated,
                          updated.name,
                          updated.rings,
                        );
                      }),
                    ),
                  if (f.isPoint)
                    action(
                      'Move',
                      Icons.open_with,
                      () => setState(() => tool = MapTool.moveLandmark),
                    ),
                  if (f.type == 'Polygon')
                    action(
                      'Redraw polygon',
                      Icons.polyline,
                      () => setState(() {
                        tool = MapTool.polygon;
                        draft.clear();
                        editingPolygon = f;
                      }),
                    ),
                  if (project!.annotations.any((a) => a.id == f.id))
                    action(
                      'Remove edit',
                      Icons.delete_outline,
                      deleteSelection,
                    ),
                ],
              ),
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(f.toGeoJson()),
            ),
          ],
          const Divider(height: 28),
          Text(
            'Capture centres',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          ...project!.centres
              .where((item) => item.floor == floor)
              .map(
                (item) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: item.id == selectedCentre,
                  leading: Icon(
                    item.panoramas.isEmpty
                        ? Icons.panorama_outlined
                        : Icons.panorama,
                    color: item.panoramas.isEmpty
                        ? Colors.deepOrange
                        : Colors.blue,
                  ),
                  title: Text(item.name),
                  subtitle: Text('${item.panoramas.length} views'),
                  onTap: () => setState(() {
                    selectedCentre = item.id;
                    selectedFeature = null;
                    tool = MapTool.select;
                    draft.clear();
                  }),
                ),
              ),
          const Divider(),
          Text(
            'Map annotations',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          ...project!.features
              .where((item) => item.floor == floor)
              .map(
                (item) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  selected: item.id == selectedFeature,
                  title: Text(item.name),
                  subtitle: Text(item.type),
                  onTap: () => setState(() {
                    selectedFeature = item.id;
                    selectedCentre = null;
                    tool = MapTool.select;
                    draft.clear();
                  }),
                ),
              ),
          TextButton.icon(
            onPressed: showImportDetails,
            icon: const Icon(Icons.info_outline),
            label: Text(
              'Import details (${project!.sourceData.warnings.length} warnings)',
            ),
          ),
          const Text(
            'Visual label recognition is experimental. No measured depth, route guidance, or exact camera localization.',
          ),
        ],
      ),
    );
  }
}
