import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Preserve the complete photo and aspect ratio; padding keeps the labeled
/// landmark at the reference centre when it was centred in the source photo.
Uint8List makeSupportingReference(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    throw const FormatException('Unable to decode landmark photo');
  }
  final image = img.bakeOrientation(decoded);
  final scale = math.min(960 / image.width, 720 / image.height);
  final resized = img.copyResize(
    image,
    width: math.max(1, (image.width * scale).round()),
    height: math.max(1, (image.height * scale).round()),
    interpolation: img.Interpolation.linear,
  );
  final canvas = img.Image(width: 960, height: 720, numChannels: 3);
  img.compositeImage(
    canvas,
    resized,
    dstX: (960 - resized.width) ~/ 2,
    dstY: (720 - resized.height) ~/ 2,
  );
  return Uint8List.fromList(img.encodePng(canvas));
}
