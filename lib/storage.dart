import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import 'domain.dart';

import 'package:flutter/foundation.dart' show compute;

import 'supporting_photo.dart';

class ProjectStore {
  ProjectStore(this.root);
  final Directory root;
  static const maxBundleBytes = 512 * 1024 * 1024;
  static const maxAssetBytes = 128 * 1024 * 1024;
  static const maxMapBytes = 16 * 1024 * 1024;
  Directory directory(String id) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(id)) {
      throw const FormatException('Invalid project ID');
    }
    return Directory(path.join(root.path, id));
  }

  static void validateAssetPath(String value) {
    if (!RegExp(r'^panoramas/[a-zA-Z0-9_-]+\.jpg$').hasMatch(value)) {
      throw const FormatException('Invalid panorama path');
    }
  }

  File asset(MapperProject p, Panorama panorama) {
    validateAssetPath(panorama.path);
    return File(path.join(directory(p.id).path, panorama.path));
  }

  static void validateReferencePath(String value) {
    if (!RegExp(r'^references/[a-zA-Z0-9_-]+\.png$').hasMatch(value)) {
      throw const FormatException('Invalid label reference path');
    }
  }

  File reference(MapperProject p, PanoramaLabel label) {
    validateReferencePath(label.referencePath);
    return File(path.join(directory(p.id).path, label.referencePath));
  }

  static Future<void> validateReference(Uint8List bytes) async {
    if (bytes.length > 8 * 1024 * 1024 ||
        bytes.length < 8 ||
        bytes[0] != 137 ||
        bytes[1] != 80 ||
        bytes[2] != 78 ||
        bytes[3] != 71) {
      throw const FormatException(
        'Expected a PNG recognition reference under 8 MB',
      );
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width != 960 || descriptor.height != 720) {
        throw const FormatException(
          'Recognition references must be 960 by 720',
        );
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<void> addLabel(
    MapperProject p,
    Panorama panorama,
    String name,
    double yaw,
    double pitch,
    Uint8List bytes, {
    String? featureId,
  }) async {
    await validateReference(bytes);
    final label = PanoramaLabel(
      id: newId(),
      name: name,
      yaw: yaw,
      pitch: pitch,
      referencePath: 'references/${newId()}.png',
      featureId: featureId,
    );
    PanoramaLabel.fromJson(label.toJson());
    await _atomic(reference(p, label), bytes);
    panorama.labels.add(label);
    try {
      await save(p);
    } catch (_) {
      panorama.labels.remove(label);
      rethrow;
    }
  }

  static void validatePhotoPath(String value) {
    if (!RegExp(r'^landmark_photos/[a-zA-Z0-9_-]+\.(jpg|png)$')
        .hasMatch(value)) {
      throw const FormatException('Invalid supporting photo path');
    }
  }

  File photoOriginal(MapperProject p, LandmarkPhoto photo) {
    validatePhotoPath(photo.originalPath);
    return File(path.join(directory(p.id).path, photo.originalPath));
  }

  File photoReference(MapperProject p, LandmarkPhoto photo) {
    validateReferencePath(photo.referencePath);
    return File(path.join(directory(p.id).path, photo.referencePath));
  }

  static Future<String> validatePhoto(Uint8List bytes) async {
    if (bytes.length < 8 || bytes.length > 32 * 1024 * 1024) {
      throw const FormatException(
        'Landmark photos must be JPG/PNG under 32 MiB',
      );
    }
    final jpg = bytes[0] == 255 && bytes[1] == 216;
    final png =
        bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71;
    if (!jpg && !png) {
      throw const FormatException('Choose a JPG or PNG landmark photo');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width < 64 ||
          descriptor.height < 64 ||
          descriptor.width * descriptor.height > 64000000) {
        throw const FormatException(
          'Landmark photo dimensions must be at least 64 px and at most 64 megapixels',
        );
      }
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
    return jpg ? 'jpg' : 'png';
  }

  Future<void> addSupportingPhoto(
    MapperProject p,
    PanoramaLabel label,
    Uint8List bytes,
  ) async {
    if (label.photos.length >= 12) {
      throw const FormatException(
        'Up to 12 separate photos per label in this pilot',
      );
    }
    final owner = p.centres
        .where((c) => c.panoramas.any((v) => v.labels.contains(label)))
        .firstOrNull;
    if (owner == null) {
      throw const FormatException('Label does not belong to this project');
    }
    final count = p.centres
        .where((c) => c.floor == owner.floor)
        .expand((c) => c.panoramas)
        .expand((v) => v.labels)
        .fold(0, (n, l) => n + 1 + l.photos.length);
    if (count >= 60) {
      throw const FormatException(
        'This floor already has 60 reference views. Remove redundant views or split the project.',
      );
    }
    final extension = await validatePhoto(bytes);
    final reference = await compute(makeSupportingReference, bytes);
    await validateReference(reference);
    final id = newId();
    final photo = LandmarkPhoto(
      id,
      'landmark_photos/$id.$extension',
      'references/$id.png',
    );
    await _atomic(photoOriginal(p, photo), bytes);
    await _atomic(photoReference(p, photo), reference);
    label.photos.add(photo);
    try {
      await save(p);
    } catch (_) {
      label.photos.remove(photo);
      rethrow;
    }
  }

  Future<void> _atomic(File file, List<int> bytes) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.${newId()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> deletePath(MapperProject project, MapFeature feature) async {
    if (feature.type != 'LineString' ||
        !project.features.any(
          (f) => f.id == feature.id && f.type == 'LineString',
        )) {
      throw const FormatException('Select an existing saved path');
    }
    final previous = List.of(project.annotations);
    try {
      final editable = project.annotations.any((f) => f.id == feature.id);
      final sourceId = editable
          ? feature.properties['source_feature_id']
          : feature.id;
      project.annotations.removeWhere((f) => f.id == feature.id);
      if (sourceId != null) {
        project.annotations.add(
          MapFeature(
            editable ? feature.id : newId(),
            feature.name,
            feature.floor,
            feature.type,
            feature.rings,
            {
              ...feature.properties,
              'source_feature_id': sourceId,
              '_mapper_deleted': true,
            },
          ),
        );
      }
      await save(project);
    } catch (_) {
      project.annotations
        ..clear()
        ..addAll(previous);
      rethrow;
    }
  }

  Future<void> save(MapperProject p) async {
    final dir = directory(p.id);
    final source = File(path.join(dir.path, 'source.json'));
    if (!await source.exists()) await _atomic(source, utf8.encode(p.source));
    await _atomic(
      File(path.join(dir.path, 'project.json')),
      utf8.encode(const JsonEncoder.withIndent('  ').convert(p.toJson())),
    );
  }

  Future<MapperProject> create(String name, String source) async {
    if (utf8.encode(source).length > maxMapBytes) {
      throw const FormatException('Map exceeds 16 MB');
    }
    final p = MapperProject(newId(), name, source, MapData.parse(source));
    await save(p);
    return p;
  }

  Future<List<({String id, String name})>> list() async {
    await root.create(recursive: true);
    final projects = <({String id, String name})>[];
    await for (final dir in root.list(followLinks: false)) {
      if (dir is! Directory || path.basename(dir.path).startsWith('.')) {
        continue;
      }
      final file = File(path.join(dir.path, 'project.json'));
      if (!await file.exists()) continue;
      try {
        final manifest = jsonDecode(await file.readAsString()) as Map;
        projects.add((
          id: path.basename(dir.path),
          name: manifest['name'] as String,
        ));
      } catch (_) {
        projects.add((
          id: path.basename(dir.path),
          name: 'Unreadable project — ${path.basename(dir.path)}',
        ));
      }
    }
    projects.sort((a, b) => a.name.compareTo(b.name));
    return projects;
  }

  Future<void> deleteProject(String id) async {
    final target = directory(id);
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException(
        'Project is missing or is not an owned directory',
      );
    }
    final rootPath = await root.resolveSymbolicLinks();
    final targetPath = await target.resolveSymbolicLinks();
    if (!path.equals(path.dirname(targetPath), rootPath) ||
        !path.equals(targetPath, path.join(rootPath, id))) {
      throw const FormatException(
        'Refusing to delete a project outside project storage',
      );
    }
    if (!await File(path.join(targetPath, 'project.json')).exists()) {
      throw const FormatException('Directory is not a mapper project');
    }
    await Directory(targetPath).delete(recursive: true);
  }

  Future<MapperProject> open(String id) async {
    final dir = directory(id);
    final p = MapperProject.fromJson(
      jsonDecode(await File(path.join(dir.path, 'project.json')).readAsString())
          as Json,
      await File(path.join(dir.path, 'source.json')).readAsString(),
    );
    if (p.id != id) {
      throw const FormatException('Project ID does not match its directory');
    }
    for (final c in p.centres) {
      for (final panorama in c.panoramas) {
        if (!await asset(p, panorama).exists()) {
          throw FormatException('Missing panorama: ${panorama.path}');
        }
        for (final label in panorama.labels) {
          if (!await reference(p, label).exists()) {
            throw FormatException(
              'Missing label reference: ${label.referencePath}',
            );
          }
          for (final photo in label.photos) {
            if (!await photoOriginal(p, photo).exists() ||
                !await photoReference(p, photo).exists()) {
              throw const FormatException(
                'Missing supporting landmark photo or reference',
              );
            }
          }
        }
      }
    }
    return p;
  }

  static Future<({int width, int height})> validateJpeg(Uint8List bytes) async {
    if (bytes.length > maxAssetBytes ||
        bytes.length < 4 ||
        bytes[0] != 0xff ||
        bytes[1] != 0xd8) {
      throw const FormatException('Choose a JPG panorama smaller than 128 MB');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if ((descriptor.width / descriptor.height - 2).abs() > .02) {
        throw const FormatException(
          'Expected a full 2:1 equirectangular panorama, not a reframed image',
        );
      }
      return (width: descriptor.width, height: descriptor.height);
    } finally {
      descriptor?.dispose();
      buffer.dispose();
    }
  }

  Future<Panorama> attach(
    MapperProject p,
    CaptureCentre c,
    Uint8List bytes, {
    Panorama? replace,
  }) async {
    await validateJpeg(bytes);
    final panorama = Panorama(
      newId(),
      'panoramas/${newId()}.jpg',
      replace?.heading ?? 0,
    );
    await _atomic(asset(p, panorama), bytes);
    final index = replace == null ? -1 : c.panoramas.indexOf(replace);
    if (replace != null && index < 0) {
      throw const FormatException('Panorama is no longer attached');
    }
    if (index < 0) {
      c.panoramas.add(panorama);
    } else {
      c.panoramas[index] = panorama;
    }
    try {
      await save(p);
    } catch (_) {
      if (index < 0) {
        c.panoramas.remove(panorama);
      } else {
        c.panoramas[index] = replace!;
      }
      rethrow;
    }
    return panorama;
  }

  Future<Uint8List> exportBundle(MapperProject p) async {
    await save(p);
    final archive = Archive();
    var total = 0;
    Future<void> add(String name, File file) async {
      if (!await file.exists()) {
        throw FormatException('Missing project asset: $name');
      }
      total += await file.length();
      if (total > maxBundleBytes) {
        throw const FormatException(
          'Pilot bundle exceeds 512 MB. Split it into smaller projects.',
        );
      }
      final bytes = await file.readAsBytes();
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    final dir = directory(p.id);
    await add('project.json', File(path.join(dir.path, 'project.json')));
    await add('source.json', File(path.join(dir.path, 'source.json')));
    final added = <String>{};
    for (final c in p.centres) {
      for (final panorama in c.panoramas) {
        if (added.add(panorama.path)) {
          await add(panorama.path, asset(p, panorama));
        }
        for (final label in panorama.labels) {
          if (added.add(label.referencePath)) {
            await add(label.referencePath, reference(p, label));
          }
          for (final photo in label.photos) {
            if (added.add(photo.originalPath)) {
              await add(photo.originalPath, photoOriginal(p, photo));
            }
            if (added.add(photo.referencePath)) {
              await add(photo.referencePath, photoReference(p, photo));
            }
          }
        }
      }
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<MapperProject> importBundle(Uint8List bytes) async {
    if (bytes.length > maxBundleBytes) {
      throw const FormatException('Bundle exceeds 512 MB');
    }
    final bundleDirectory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (bundleDirectory.fileHeaders.isEmpty ||
        bundleDirectory.fileHeaders.length > 10000) {
      throw const FormatException('Empty or excessive bundle directory');
    }
    var total = 0;
    final seen = <String>{};
    // Validate central-directory metadata before decoding image contents. The ZIP
    // decoder otherwise coalesces identical names and its verify flag is not a
    // substitute for explicitly checking each decoded entry's CRC.
    for (final header in bundleDirectory.fileHeaders) {
      final name = header.filename;
      if (name.contains('\\') ||
          name.startsWith('/') ||
          name.split('/').contains('..') ||
          name.contains(':') ||
          (header.externalFileAttributes >> 16 & 0xf000) == 0xa000 ||
          (header.generalPurposeBitFlag & 1) != 0 ||
          header.file?.filename != name) {
        throw const FormatException(
          'Unsafe archive path, symbolic link, or encrypted entry',
        );
      }
      if (!seen.add(name.toLowerCase())) {
        throw const FormatException('Duplicate bundle entry');
      }
      if (name.endsWith('/')) {
        if (!['panoramas/', 'references/', 'landmark_photos/'].contains(name) ||
            header.uncompressedSize != 0) {
          throw const FormatException('Unexpected bundle directory');
        }
        continue;
      }
      if (name != 'project.json' && name != 'source.json') {
        if (name.startsWith('landmark_photos/')) {
          validatePhotoPath(name);
        } else if (name.startsWith('references/')) {
          validateReferencePath(name);
        } else {
          validateAssetPath(name);
        }
      }
      if (header.uncompressedSize >
          (name.endsWith('.json') ? maxMapBytes : maxAssetBytes)) {
        throw const FormatException('Bundle entry too large');
      }
      total += header.uncompressedSize;
      if (total > maxBundleBytes) {
        throw const FormatException('Expanded bundle too large');
      }
    }
    final files = <String, Uint8List>{};
    for (final header in bundleDirectory.fileHeaders) {
      if (header.filename.endsWith('/')) continue;
      final content = header.file!.getStream().toUint8List();
      if (content.length != header.uncompressedSize ||
          getCrc32(content) != header.crc32) {
        throw const FormatException('Bundle entry length or checksum mismatch');
      }
      files[header.filename] = content;
    }
    if (!files.containsKey('project.json') ||
        !files.containsKey('source.json')) {
      throw const FormatException('Bundle needs project.json and source.json');
    }
    final p = MapperProject.fromJson(
      jsonDecode(utf8.decode(files['project.json']!)) as Json,
      utf8.decode(files['source.json']!),
    );
    final referenced = <String>{'project.json', 'source.json'};
    for (final c in p.centres) {
      for (final panorama in c.panoramas) {
        validateAssetPath(panorama.path);
        if (!files.containsKey(panorama.path)) {
          throw FormatException('Missing panorama: ${panorama.path}');
        }
        if (referenced.add(panorama.path)) {
          await validateJpeg(files[panorama.path]!);
        }
        for (final label in panorama.labels) {
          validateReferencePath(label.referencePath);
          if (!files.containsKey(label.referencePath)) {
            throw FormatException(
              'Missing label reference: ${label.referencePath}',
            );
          }
          if (referenced.add(label.referencePath)) {
            await validateReference(files[label.referencePath]!);
          }
          for (final photo in label.photos) {
            validatePhotoPath(photo.originalPath);
            validateReferencePath(photo.referencePath);
            if (!files.containsKey(photo.originalPath) ||
                !files.containsKey(photo.referencePath)) {
              throw const FormatException(
                'Bundle is missing a supporting photo or its reference',
              );
            }
            if (referenced.add(photo.originalPath)) {
              await validatePhoto(files[photo.originalPath]!);
            }
            if (referenced.add(photo.referencePath)) {
              await validateReference(files[photo.referencePath]!);
            }
          }
        }
      }
    }
    if (files.keys.any((name) => !referenced.contains(name))) {
      throw const FormatException('Bundle contains unreferenced files');
    }
    // Each import is a new local copy; never overwrite an existing project.
    final copy = MapperProject(
      newId(),
      p.name,
      p.source,
      p.sourceData,
      annotations: p.annotations,
      centres: p.centres,
      grids: p.grids,
    );
    await root.create(recursive: true);
    final staging = Directory(path.join(root.path, '.import-${copy.id}'));
    try {
      await staging.create();
      for (final name in referenced) {
        if (name == 'project.json') continue;
        final file = File(path.join(staging.path, name));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(files[name]!, flush: true);
      }
      await File(path.join(staging.path, 'project.json'))
          .writeAsString(jsonEncode(copy.toJson()), flush: true);
      await staging.rename(directory(copy.id).path);
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
    return copy;
  }
}
