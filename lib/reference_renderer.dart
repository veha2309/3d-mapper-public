import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Runs in a worker isolate. Uses the same rays as the interactive sphere shader,
/// but makes portable image references independent of a GPU readback operation.
Uint8List renderPerspectivePng(Map<String, dynamic> input) {
  final pixels = input['pixels'] as Uint8List;
  final width = input['width'] as int, height = input['height'] as int;
  final yaw = input['yaw'] as double, pitch = input['pitch'] as double;
  final outputWidth = input['output_width'] as int? ?? 960,
      outputHeight = input['output_height'] as int? ?? 720;
  final fov = input['fov'] as double? ?? 55;
  final output = Uint8List(outputWidth * outputHeight * 4);
  final cy = math.cos(yaw),
      sy = math.sin(yaw),
      cp = math.cos(pitch),
      sp = math.sin(pitch);
  final tangent = math.tan(fov * math.pi / 360),
      aspect = outputWidth / outputHeight;
  for (var y = 0; y < outputHeight; y++) {
    final ry = -((y + .5) / outputHeight - .5) * 2 * tangent;
    for (var x = 0; x < outputWidth; x++) {
      final rx = ((x + .5) / outputWidth - .5) * 2 * aspect * tangent;
      final yp = ry * cp + sp, zp = -ry * sp + cp;
      final xx = rx * cy + zp * sy, zz = -rx * sy + zp * cy;
      final length = math.sqrt(xx * xx + yp * yp + zz * zz);
      final u = (math.atan2(xx, zz) / (2 * math.pi) + .5) * width - .5;
      final v =
          ((.5 - math.asin((yp / length).clamp(-1, 1)) / math.pi) * height - .5)
              .clamp(0, height - 1);
      final left = u.floor(), top = v.floor(), fx = u - left, fy = v - top;
      final right = (left + 1) % width, bottom = math.min(top + 1, height - 1);
      final x0 = left % width;
      final target = (y * outputWidth + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        final a =
            pixels[(top * width + x0) * 4 + channel] * (1 - fx) +
            pixels[(top * width + right) * 4 + channel] * fx;
        final b =
            pixels[(bottom * width + x0) * 4 + channel] * (1 - fx) +
            pixels[(bottom * width + right) * 4 + channel] * fx;
        output[target + channel] = (a * (1 - fy) + b * fy).round().clamp(
          0,
          255,
        );
      }
      output[target + 3] = 255;
    }
  }
  return Uint8List.fromList(
    img.encodePng(
      img.Image.fromBytes(
        width: outputWidth,
        height: outputHeight,
        bytes: output.buffer,
        numChannels: 4,
      ),
    ),
  );
}
