import 'dart:math' as math;
import 'dart:ui';

class ViewDirection {
  const ViewDirection(this.yaw, this.pitch);
  final double yaw, pitch;
}

ViewDirection directionAt(
  Offset point,
  Size size,
  double yaw,
  double pitch,
  double fov,
) {
  final tangent = math.tan(fov * math.pi / 360);
  var x = (point.dx / size.width - .5) * 2 * size.width / size.height * tangent;
  var y = -(point.dy / size.height - .5) * 2 * tangent;
  var z = 1.0;
  final length = math.sqrt(x * x + y * y + z * z);
  x /= length;
  y /= length;
  z /= length;
  final yp = y * math.cos(pitch) + z * math.sin(pitch),
      zp = -y * math.sin(pitch) + z * math.cos(pitch);
  return ViewDirection(
    math.atan2(
      x * math.cos(yaw) + zp * math.sin(yaw),
      -x * math.sin(yaw) + zp * math.cos(yaw),
    ),
    math.asin(yp.clamp(-1, 1)),
  );
}

Offset? screenDirection(
  ViewDirection point,
  Size size,
  double yaw,
  double pitch,
  double fov,
) {
  final x = math.sin(point.yaw) * math.cos(point.pitch),
      y = math.sin(point.pitch),
      z = math.cos(point.yaw) * math.cos(point.pitch);
  final xp = x * math.cos(yaw) - z * math.sin(yaw),
      zp = x * math.sin(yaw) + z * math.cos(yaw);
  final yc = y * math.cos(pitch) - zp * math.sin(pitch),
      zc = y * math.sin(pitch) + zp * math.cos(pitch);
  if (zc <= 0) return null;
  final t = math.tan(fov * math.pi / 360);
  final ndcX = xp / zc / (size.width / size.height * t), ndcY = -yc / zc / t;
  if (ndcX.abs() > 1 || ndcY.abs() > 1) return null;
  return Offset((ndcX / 2 + .5) * size.width, (ndcY / 2 + .5) * size.height);
}
