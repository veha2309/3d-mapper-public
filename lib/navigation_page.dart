import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'domain.dart';
import 'navigation.dart';
import 'recognition_page.dart';
import 'route_indicators.dart';
import 'storage.dart';
import 'path_editor.dart';

class NavigationPage extends StatefulWidget {
  const NavigationPage({
    super.key,
    required this.project,
    required this.store,
    required this.floor,
    this.onProjectChanged,
  });
  final MapperProject project;
  final ProjectStore store;
  final String floor;
  final ValueChanged<MapperProject>? onProjectChanged;
  @override
  State<NavigationPage> createState() => _NavigationPageState();
}

class _NavigationPageState extends State<NavigationPage> {
  late MapperProject project = widget.project;
  bool draftPreview = false, loading = false;
  RouteNetwork get network => RouteNetwork(
    project.features,
    widget.floor,
    includeUnreviewed: draftPreview,
  );
  List<MapFeature> get paths => project.features
      .where((f) => f.floor == widget.floor && f.type == 'LineString')
      .toList();
  Future<void> editPaths([MapFeature? path]) async {
    stopSpeech();
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => PathEditorPage(
          project: project,
          store: widget.store,
          floor: widget.floor,
          initialPath: path,
        ),
      ),
    );
    if (!mounted) return;
    widget.onProjectChanged?.call(project);
    setState(() {
      from = null;
      to = null;
      plan = null;
      guidance = null;
      error = null;
    });
  }

  Future<void> refreshPaths() async {
    stopSpeech();
    setState(() => loading = true);
    try {
      final updated = await widget.store.open(project.id);
      if (!mounted) return;
      widget.onProjectChanged?.call(updated);
      setState(() {
        project = updated;
        from = null;
        to = null;
        plan = null;
        guidance = null;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = 'Could not reload paths: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String? from, to, error;
  RoutePlan? plan;
  RouteGuidance? guidance;
  int selected = 0;
  double? previewHeading;
  String? arrivalFeatureId;
  ArrivalPreview get arrival => plan!.arrivalPreview(
    scene.heading,
    project.features,
    destinationFeatureId: arrivalFeatureId,
  );
  FacingScene get scene {
    final step = guidance!.steps[selected];
    final index = step.startIndex;
    final heading = index < plan!.nodes.length - 1
        ? bearing(plan!.nodes[index].position, plan!.nodes[index + 1].position)
        : bearing(plan!.nodes[index - 1].position, plan!.nodes[index].position);
    return plan!.facingScene(step, previewHeading ?? heading, project.features);
  }

  final stepCardKey = GlobalKey();
  final panelScroll = ScrollController(), mobileScroll = ScrollController();
  static const speech = MethodChannel('three_d_mapper/recognition');
  void preview() {
    stopSpeech();
    try {
      final route = network.plan(from ?? '', to ?? '');
      setState(() {
        plan = route;
        guidance = route.guidance(project.features);
        selected = 0;
        arrivalFeatureId = null;
        error = null;
      });
    } catch (e) {
      setState(() {
        error = '$e';
        plan = null;
        guidance = null;
      });
    }
  }

  void stopSpeech() {
    if (Platform.isAndroid) {
      speech.invokeMethod<void>('stopSpeech').catchError((_) {});
    }
  }

  void select(int index) {
    stopSpeech();
    setState(() => selected = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final target = stepCardKey.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          duration: const Duration(milliseconds: 200),
          alignment: .1,
        );
      }
    });
  }

  Future<void> read(String text) async {
    try {
      await speech.invokeMethod<void>('speakRoutePreview', {'text': text});
    } catch (e) {
      if (mounted) setState(() => error = 'Speech unavailable: $e');
    }
  }

  @override
  void dispose() {
    stopSpeech();
    panelScroll.dispose();
    mobileScroll.dispose();
    super.dispose();
  }

  Widget setup() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Planning preview · current position and facing direction are not verified.',
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${paths.length} saved paths · ${paths.where((p) => p.properties['reviewed'] == true).length} reviewed',
              ),
              TextButton.icon(
                onPressed: loading ? null : refreshPaths,
                icon: const Icon(Icons.refresh),
                label: const Text('Reload saved paths'),
              ),
              if (Platform.isWindows)
                TextButton.icon(
                  onPressed: () => editPaths(),
                  icon: const Icon(Icons.edit_road),
                  label: const Text('Open Path editor'),
                ),
            ],
          ),
        ),
        if (paths.any((p) => p.properties['reviewed'] != true))
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Preview unreviewed paths'),
            subtitle: const Text(
              'Inspect draft routes without marking them as reviewed.',
            ),
            value: draftPreview,
            onChanged: (value) {
              stopSpeech();
              setState(() {
                draftPreview = value;
                from = null;
                to = null;
                plan = null;
                guidance = null;
              });
            },
          ),
        if (draftPreview)
          Container(
            padding: const EdgeInsets.all(8),
            color: Colors.amber.shade100,
            child: const Text(
              'Draft preview includes unreviewed paths. This is not a checked route.',
            ),
          ),
        if (network.nodes.isNotEmpty)
          LayoutBuilder(
            builder: (context, constraints) {
              final fields = [
                for (final origin in [true, false])
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      '${origin ? 'from' : 'to'}-${origin ? from : to}-$draftPreview',
                    ),
                    initialValue: origin ? from : to,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: origin ? 'Mapped start' : 'Mapped destination',
                    ),
                    items: network.nodes.values
                        .map(
                          (node) => DropdownMenuItem(
                            value: node.id,
                            child: Text(
                              node.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      stopSpeech();
                      setState(() {
                        if (origin) {
                          from = value;
                        } else {
                          to = value;
                        }
                        plan = null;
                        guidance = null;
                        error = null;
                      });
                    },
                  ),
              ];
              if (constraints.maxWidth < 560) {
                return Column(
                  children: [
                    const SizedBox(height: 12),
                    fields[0],
                    const SizedBox(height: 12),
                    fields[1],
                  ],
                );
              }
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(child: fields[0]),
                    const SizedBox(width: 16),
                    Expanded(child: fields[1]),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        if (network.nodes.isNotEmpty)
          FilledButton.icon(
            onPressed: from == null || to == null ? null : preview,
            icon: const Icon(Icons.route),
            label: const Text('Describe mapped route'),
          ),
        if (error != null) Text(error!),
      ],
    ),
  );
  Widget diagram() => RouteDiagram(
    features: project.features.where((f) => f.floor == widget.floor).toList(),
    plan: plan!,
    guidance: guidance!,
    selected: selected,
    facingHeading: scene.heading,
    destinationFeatureId: arrival.feature?.id,
    onStep: select,
  );
  Widget emptyContent() => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          network.nodes.isEmpty
              ? (paths.isEmpty
                    ? 'No saved paths on this floor. Create a path and press Save path before previewing a route.'
                    : 'Your paths are saved but none are reviewed. Open a path to check and save its walkability, or enable Preview unreviewed paths to inspect the draft.')
              : 'Choose a start and destination to see the route, arrows and turn-by-turn steps.',
        ),
        if (network.nodes.isEmpty)
          for (final path in paths)
            Card(
              child: ListTile(
                title: Text(path.name),
                subtitle: Text(
                  path.properties['reviewed'] == true
                      ? 'Reviewed'
                      : 'Needs walkability review',
                ),
                trailing: Platform.isWindows
                    ? TextButton(
                        onPressed: () => editPaths(path),
                        child: const Text('Review / edit'),
                      )
                    : null,
              ),
            ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Route preview')),
    body: LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 960 || constraints.maxHeight < 500) {
          return ListView(
            controller: mobileScroll,
            children: [
              setup(),
              if (guidance == null)
                emptyContent()
              else ...[
                SizedBox(height: 280, child: diagram()),
                steps(scrollable: false),
              ],
            ],
          );
        }
        return Column(
          children: [
            setup(),
            Expanded(
              child: guidance == null
                  ? ListView(children: [emptyContent()])
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: diagram()),
                        const VerticalDivider(width: 1),
                        SizedBox(width: 430, child: steps()),
                      ],
                    ),
            ),
          ],
        );
      },
    ),
  );
  Widget steps({bool scrollable = true}) {
    final result = guidance!, step = result.steps[selected];
    final children = <Widget>[
      Text(result.overview, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 12),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: const Text('Before you start'),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(result.orientation),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Card(
        key: stepCardKey,
        color: Colors.indigo.shade50,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PREVIEW STEP ${selected + 1} OF ${result.steps.length}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<double>(
                initialValue: previewHeading ?? -1,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Facing direction for this preview',
                ),
                items: [
                  const DropdownMenuItem(
                    value: -1,
                    child: Text(
                      'Planned direction after turn',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (var i = 0; i < 8; i++)
                    DropdownMenuItem(
                      value: i * 45.0,
                      child: Text(cardinal(i * 45.0)),
                    ),
                ],
                onChanged: (value) {
                  stopSpeech();
                  setState(
                    () => previewHeading = value == null || value < 0
                        ? null
                        : value,
                  );
                },
              ),
              const SizedBox(height: 8),
              Text(
                previewHeading == null
                    ? 'Facing after the planned turn: ${cardinal(scene.heading)} (preview).'
                    : scene.header,
              ),
              const Text(
                'Selected preview orientation, not a phone heading measurement.',
              ),
              if (step.action == RouteAction.finish) ...[
                const SizedBox(height: 12),
                const Text('ARRIVAL ANNOUNCEMENT PREVIEW'),
                DropdownButtonFormField<String>(
                  key: ValueKey('arrival-${arrival.feature?.id}'),
                  initialValue: arrival.feature?.id,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Destination room / landmark',
                  ),
                  items: plan!
                      .arrivalCandidates(project.features)
                      .map(
                        (f) => DropdownMenuItem(
                          value: f.id,
                          child: Text(
                            '${f.name} · ${f.isPoint ? 'point' : 'area'}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    stopSpeech();
                    setState(() => arrivalFeatureId = value);
                  },
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    step.action == RouteAction.finish && arrival.side != null
                        ? (arrival.side!.contains('left')
                              ? Icons.arrow_back
                              : arrival.side!.contains('right')
                              ? Icons.arrow_forward
                              : arrival.side == 'ahead'
                              ? Icons.arrow_upward
                              : Icons.arrow_downward)
                        : routeIcon(
                            previewHeading == null
                                ? step.action
                                : scene.alignmentAction,
                          ),
                    size: 48,
                    color: Colors.indigo,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      previewHeading == null
                          ? step.title
                          : actionLabel(scene.alignmentAction),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  step.action == RouteAction.finish
                      ? arrival.announcement
                      : previewHeading == null
                      ? step.instruction
                      : scene.alignment,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (step.action == RouteAction.finish)
                Text(
                  arrival.side == null ? arrival.reason : 'Side is based on the selected facing direction and mapped destination. Live arrival is not confirmed.',
                ),
              if (step.action != RouteAction.finish)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '${distanceWords(step.remainingMetres)} of the planned route from this step.',
                  ),
                ),
              if (Platform.isAndroid)
                TextButton.icon(
                  onPressed: () => read(
                    step.action == RouteAction.finish
                        ? arrival.spoken
                        : '${draftPreview ? 'Unreviewed draft. ' : ''}Preview step ${selected + 1}. ${selected == 0 ? result.orientation : ''} ${previewHeading == null ? '${step.instruction} Planned facing after the turn: ${cardinal(scene.heading)}.' : '${scene.header} ${scene.alignment}'}',
                  ),
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Read this step'),
                ),
              if (step.action != RouteAction.finish)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Surroundings from this orientation'),
                  subtitle: const Text(
                    'Map relationships; visibility and current obstacles are not measured.',
                  ),
                  children: [
                    if (scene.landmarks.isEmpty)
                      const Text(
                        'No distinctive mapped landmarks within 10 metres of this waypoint.',
                      ),
                    for (final landmark in scene.landmarks)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.explore_outlined),
                        title: Text(landmark.text),
                      ),
                    if (Platform.isAndroid)
                      TextButton.icon(
                        onPressed: () => read(scene.spoken),
                        icon: const Icon(Icons.volume_up),
                        label: const Text('Read surroundings'),
                      ),
                  ],
                ),
              if (step.context.isNotEmpty && step.action != RouteAction.finish)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Surrounding context'),
                  children: [
                    for (final context in step.context)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(context),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
      Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: selected == 0 ? null : () => select(selected - 1),
              child: const Text('Previous step'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: FilledButton(
              onPressed: selected == result.steps.length - 1
                  ? null
                  : () => select(selected + 1),
              child: const Text('Next preview step'),
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Text('Turn-by-turn plan', style: Theme.of(context).textTheme.titleMedium),
      for (var i = 0; i < result.steps.length; i++)
        ListTile(
          key: ValueKey('route-step-$i'),
          selected: i == selected,
          selectedTileColor: Colors.indigo.shade50,
          leading: Icon(routeIcon(result.steps[i].action)),
          title: Text('${i + 1}. ${result.steps[i].title}'),
          subtitle: Text(result.steps[i].instruction),
          onTap: () => select(i),
        ),
      if (Platform.isAndroid) ...[
        TextButton.icon(
          onPressed: () => read(
            '${draftPreview ? 'Unreviewed draft. ' : ''}${result.spokenPreview}',
          ),
          icon: const Icon(Icons.volume_up),
          label: const Text('Read route preview aloud'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            stopSpeech();
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => RecognitionPage(
                  project: project,
                  store: widget.store,
                  floor: widget.floor,
                ),
              ),
            );
          },
          icon: const Icon(Icons.camera_alt),
          label: const Text('Check visible landmarks with camera'),
        ),
      ],
    ];
    return scrollable
        ? ListView(
            controller: panelScroll,
            padding: const EdgeInsets.all(16),
            children: children,
          )
        : Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          );
  }
}
