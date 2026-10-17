import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

import 'domain.dart';
import 'storage.dart';
import 'test_logs.dart';
import 'test_logs_page.dart';
import 'candidate_diagnostics.dart';

class RecognitionPage extends StatefulWidget {
  const RecognitionPage({
    super.key,
    required this.project,
    required this.store,
    required this.floor,
  });
  final MapperProject project;
  final ProjectStore store;
  final String floor;
  @override
  State<RecognitionPage> createState() => _RecognitionPageState();
}

class _RecognitionPageState extends State<RecognitionPage>
    with WidgetsBindingObserver {
  static const methods = MethodChannel('three_d_mapper/recognition');
  static const events = EventChannel('three_d_mapper/recognition/events');
  StreamSubscription<dynamic>? subscription;
  Timer? freshness;
  TestLogSession? session;
  String? loggingError;
  Map<String, dynamic> result = {
    'state': 'loading',
    'message': 'Preparing test log…',
  };
  String engine = 'aliked-lightglue';
  int cameraGeneration = 0;
  bool permitted = false, active = true, logsOpen = false, details = false;
  bool sampleBusy = false;
  String? sampleStatus;
  DateTime lastEvent = DateTime.now();
  List<Map<String, dynamic>> get references => [
    for (final centre in widget.project.centres.where(
      (c) => c.floor == widget.floor,
    ))
      for (final panorama in centre.panoramas)
        for (final label in panorama.labels) ...[
          {
            'id': label.id,
            'label_id': label.id,
            'identity_id': label.id,
            'source': 'panorama',
            'name': label.name,
            'centre': centre.name,
            'centre_id': centre.id,
            'floor': centre.floor,
            'path': widget.store.reference(widget.project, label).path,
            if (label.featureId != null) 'feature_id': label.featureId,
          },
          for (final photo in label.photos)
            {
              'id': photo.id,
              'label_id': label.id,
              'identity_id': label.id,
              'source': 'separate_photo',
              'name': label.name,
              'centre': centre.name,
              'centre_id': centre.id,
              'floor': centre.floor,
              'path': widget.store.photoReference(widget.project, photo).path,
              'original_path': widget.store
                  .photoOriginal(widget.project, photo)
                  .path,
              if (label.featureId != null) 'feature_id': label.featureId,
            },
        ],
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    initialize();
  }

  Future<void> initialize() async {
    try {
      final created = await TestLogSession.create(
        testLogDirectory(widget.store.root),
        {
          'log_format_version': 1,
          'app_version': '0.9.2',
          'project_id': widget.project.id,
          'project_name': widget.project.name,
          'floor': widget.floor,
          'platform': Platform.operatingSystem,
          'os_version': Platform.operatingSystemVersion,
          'reference_count': references.length,
          'references': references
              .map(
                (r) => Map<String, dynamic>.from(r)
                  ..remove('path')
                  ..remove('original_path'),
              )
              .toList(),
          'camera_images_recorded': false,
          'engine': engine,
        },
      );
      if (!mounted) {
        await created.close();
        return;
      }
      session = created;
    } catch (e) {
      loggingError = 'Test logging unavailable: $e';
    }
    if (mounted) await start();
  }

  void receive(Map<String, dynamic> value, {String? kind}) {
    final type = kind ?? '${value['event'] ?? 'status'}';
    unawaited(session?.record(type, value) ?? Future.value());
    if (mounted) setState(() => result = value);
  }

  Future<void> start() async {
    if (!Platform.isAndroid) {
      receive({
        'state': 'error',
        'reason': 'unsupported_platform',
        'message': 'Live recognition testing is available on Android only.',
      });
      return;
    }
    if (references.isEmpty) {
      receive({
        'state': 'error',
        'reason': 'no_references',
        'message': 'No panorama labels on this floor. Label views on Windows, export, and import the updated project.',
      });
      return;
    }
    if (references.length > 60) {
      receive({
        'state': 'error',
        'reason': 'reference_limit',
        'message': 'This pilot supports up to 60 labeled views per floor. Split this survey into smaller projects.',
      });
      return;
    }
    try {
      receive({
        'state': 'loading',
        'message': 'Requesting camera permission…',
      }, kind: 'permission_request');
      final allowed =
          await methods.invokeMethod<bool>('requestPermission') ?? false;
      if (!mounted) return;
      unawaited(
        session?.record('permission_result', {'allowed': allowed}) ??
            Future.value(),
      );
      if (!allowed) {
        receive({
          'state': 'error',
          'reason': 'permission_denied',
          'message': 'Camera permission was denied. Allow camera access in Android settings, then reopen this test.',
        });
        return;
      }
      subscription = events.receiveBroadcastStream().listen(
        (dynamic value) {
          if (!mounted || !active) return;
          lastEvent = DateTime.now();
          receive(Map<String, dynamic>.from(value as Map));
        },
        onError: (Object error) {
          receive({
            'state': 'error',
            'reason': 'event_stream_error',
            'message': '$error',
          });
        },
      );
      setState(() => permitted = true);
      freshness = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted &&
            result['state'] == 'recognized' &&
            DateTime.now().difference(lastEvent).inMilliseconds > 1800) {
          receive({
            'state': 'searching',
            'reason': 'stale_evidence',
            'message': 'No fresh camera evidence. Point the camera at a labeled landmark.',
          }, kind: 'freshness_reset');
        }
      });
    } catch (e) {
      if (mounted) {
        receive({
          'state': 'error',
          'reason': 'camera_start_error',
          'message': 'Unable to start camera: $e',
        });
      }
    }
  }

  Future<void> openLogs() async {
    setState(() {
      logsOpen = true;
      active = false;
    });
    unawaited(
      session?.record('pause', {'reason': 'review_logs'}) ?? Future.value(),
    );
    await session?.flush();
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TestLogsPage(
          directory: testLogDirectory(widget.store.root),
          current: session,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {
      logsOpen = false;
      active =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    });
    receive({
      'state': 'searching',
      'message': 'Camera test resumed — collecting fresh evidence.',
    }, kind: 'resume');
  }

  Future<void> saveFailedView() async {
    final labels = <String, String>{
      for (final ref in references) '${ref['label_id']}': '${ref['name']}',
    };
    String? expected;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save failed view'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Keep the camera aimed at the place that failed. This saves a camera image, matching reference photos and diagnostic points into a local ZIP. Nothing is uploaded.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: 'Place you are testing',
              ),
              items: labels.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged: (value) => expected = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save sample'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() {
      sampleBusy = true;
      sampleStatus = 'Preparing camera sample…';
    });
    String? temporary;
    try {
      final result = await methods.invokeMapMethod<String, dynamic>(
        'saveRecognitionSample',
        {'expected_label_id': expected},
      );
      temporary = result?['path'] as String?;
      if (temporary == null) {
        throw const FormatException('No camera sample returned');
      }
      final file = File(temporary);
      if (await file.length() > 80 * 1024 * 1024) {
        throw const FormatException('Sample is too large to export');
      }
      final bytes = await file.readAsBytes();
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Save recognition sample',
        fileName: file.uri.pathSegments.last,
        type: FileType.custom,
        allowedExtensions: ['zip'],
        bytes: bytes,
      );
      unawaited(
        session?.record('diagnostic_sample', {
              'saved': saved != null,
              'expected_label_id': expected,
              'includes_camera_image': true,
            }) ??
            Future.value(),
      );
      if (mounted) {
        setState(
          () => sampleStatus = saved == null
              ? 'Sample export cancelled.'
              : 'Sample saved. Share this ZIP for diagnosis.',
        );
      }
    } catch (error) {
      if (mounted) {
        setState(() => sampleStatus = 'Could not save sample: $error');
      }
    } finally {
      if (temporary != null) {
        try {
          await methods.invokeMethod<void>('discardRecognitionSample', {
            'path': temporary,
          });
        } catch (_) {}
      }
      if (mounted) setState(() => sampleBusy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(
      session?.record('lifecycle', {'state': state.name}) ?? Future.value(),
    );
    final resumed = state == AppLifecycleState.resumed && !logsOpen;
    if (active == resumed) return;
    setState(() => active = resumed);
    receive({
      'state': resumed ? 'searching' : 'paused',
      'message': resumed ? 'Looking for labeled places…' : 'Camera test paused',
    }, kind: 'camera_lifecycle');
    if (Platform.isAndroid && permitted) {
      methods.invokeMethod<void>('reset').catchError((_) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    subscription?.cancel();
    freshness?.cancel();
    unawaited(session?.close() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recognized = result['state'] == 'recognized';
    final candidates = result['candidates'] as List? ?? [];
    final problem = session?.error ?? loggingError;
    return Scaffold(
      appBar: AppBar(
        title: Text('Camera test · floor ${widget.floor}'),
        actions: [
          TextButton.icon(
            onPressed: openLogs,
            icon: const Icon(Icons.receipt_long),
            label: const Text('Test logs'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Text('Recognition: '),
                Expanded(
                  child: DropdownButton<String>(
                    value: engine,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: 'aliked-lightglue',
                        child: Text('ALIKED + LightGlue'),
                      ),
                      DropdownMenuItem(
                        value: 'orb-sift',
                        child: Text('ORB / SIFT comparison'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value == null || value == engine) return;
                      unawaited(
                        session?.record('engine_change', {'engine': value}) ??
                            Future.value(),
                      );
                      setState(() {
                        engine = value;
                        cameraGeneration++;
                        result = {
                          'state': 'loading',
                          'message': 'Preparing recognition model…',
                        };
                        lastEvent = DateTime.now();
                      });
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: permitted && active
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      AndroidView(
                        key: ValueKey('$active-$engine-$cameraGeneration'),
                        viewType: 'three_d_mapper/recognition-camera',
                        creationParams: {
                          'references': references,
                          'engine': engine,
                        },
                        creationParamsCodec: const StandardMessageCodec(),
                      ),
                      const IgnorePointer(
                        child: Center(
                          child: Icon(Icons.add, color: Colors.white, size: 36),
                        ),
                      ),
                    ],
                  )
                : Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('${result['message'] ?? 'Camera paused'}'),
                    ),
                  ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .46,
            ),
            child: SingleChildScrollView(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                color: recognized
                    ? Colors.green.shade50
                    : Colors.blueGrey.shade50,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recognized
                          ? 'Recognized: ${result['name']}'
                          : '${result['message'] ?? 'Looking for labeled places…'}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (recognized)
                      Text(
                        'Reference: ${result['centre']} · ${result['position'] ?? ''} in camera view',
                      ),
                    Text(
                      '${result['inliers'] ?? 0} inliers · ${result['streak'] ?? 0}/3 frames · ${result['matcher'] ?? (engine == 'aliked-lightglue' ? 'ALIKED + LightGlue' : 'ORB + SIFT')} · ${result['processing_ms'] ?? '—'} ms',
                    ),
                    if (!recognized && result['hint'] != null)
                      Text('${result['hint']}'),
                    if (problem != null)
                      Text(problem, style: const TextStyle(color: Colors.red)),
                    if (session?.limited ?? false)
                      const Text(
                        'Log is full. Start a new test to continue recording.',
                        style: TextStyle(color: Colors.deepOrange),
                      ),
                    TextButton(
                      onPressed: () => setState(() => details = !details),
                      child: Text(
                        details ? 'Hide diagnostics' : 'Show diagnostics',
                      ),
                    ),
                    TextButton.icon(
                      onPressed: sampleBusy || !permitted || !active
                          ? null
                          : saveFailedView,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(
                        sampleBusy ? 'Preparing sample…' : 'Save failed view',
                      ),
                    ),
                    if (sampleStatus != null) Text(sampleStatus!),
                    if (details) ...[
                      Text(
                        'Reason: ${result['reason'] ?? '—'} · query keypoints: ${result['query_keypoints'] ?? '—'} · loaded views: ${result['loaded'] ?? '—'}',
                      ),
                      if (result['retrieval_checked'] != null)
                        Text(
                          'Ranked ${result['retrieval_checked']} views · LightGlue checked ${result['neural_checked']} · retrieval ${result['retrieval_ms']} ms',
                        ),
                      if (result['quality'] is Map)
                        Text('Image quality: ${result['quality']}'),
                      CandidateDiagnostics(candidates: candidates),
                      if (result['warnings'] is List)
                        for (final warning in (result['warnings'] as List).take(
                          3,
                        ))
                          Text('$warning'),
                    ],
                    const Text(
                      'Diagnostic logs save locally without camera images. This is visible-label recognition, not a measured position or arrival.',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
