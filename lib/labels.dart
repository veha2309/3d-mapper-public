import 'dart:math' as math;

class PanoramaLabel {
  PanoramaLabel({
    required this.id,
    required this.name,
    required this.yaw,
    required this.pitch,
    required this.referencePath,
    this.featureId,
    this.verticalFov = 55,
    List<LandmarkPhoto>? photos,
  }) : photos = photos ?? [];
  final String id, referencePath;
  String name;
  final List<LandmarkPhoto> photos;
  final String? featureId;
  final double yaw, pitch, verticalFov;
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'yaw_rad': yaw,
    'pitch_rad': pitch,
    'vertical_fov_deg': verticalFov,
    'reference_path': referencePath,
    'photos': photos.map((p) => p.toJson()).toList(),
    if (featureId != null) 'feature_id': featureId,
  };
  factory PanoramaLabel.fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String;
    final yaw = (j['yaw_rad'] as num).toDouble(),
        pitch = (j['pitch_rad'] as num).toDouble();
    final fov = (j['vertical_fov_deg'] as num).toDouble();
    if (name.trim().isEmpty ||
        name.length > 160 ||
        !yaw.isFinite ||
        !pitch.isFinite ||
        yaw.abs() > math.pi + 1e-8 ||
        pitch.abs() > math.pi / 2 ||
        !fov.isFinite ||
        fov < 30 ||
        fov > 90) {
      throw const FormatException(
        'Invalid panorama label or viewing direction',
      );
    }
    return PanoramaLabel(
      id: j['id'] as String,
      name: name,
      yaw: yaw,
      pitch: pitch,
      verticalFov: fov,
      referencePath: j['reference_path'] as String,
      featureId: j['feature_id'] as String?,
      photos: (j['photos'] as List? ?? [])
          .map((p) => LandmarkPhoto.fromJson(Map<String, dynamic>.from(p)))
          .toList(),
    );
  }
}

class LandmarkPhoto {
  LandmarkPhoto(this.id, this.originalPath, this.referencePath);
  final String id, originalPath, referencePath;
  Map<String, dynamic> toJson() => {
    'id': id,
    'original_path': originalPath,
    'reference_path': referencePath,
  };
  factory LandmarkPhoto.fromJson(Map<String, dynamic> j) => LandmarkPhoto(
    j['id'] as String,
    j['original_path'] as String,
    j['reference_path'] as String,
  );
}
