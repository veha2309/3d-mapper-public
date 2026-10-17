"""Offline vision experiments. Outputs are diagnostics, never navigation authority."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import platform
import importlib.metadata
import time
from pathlib import Path

import cv2
import numpy as np


def finite_array(value, shape, name):
    result = np.asarray(value, dtype=np.float64)
    if result.shape != shape or not np.isfinite(result).all():
        raise ValueError(f"{name} must be finite with shape {shape}")
    return result


def load_dataset(filename):
    """Require whole-session and exact-image separation before any inference."""
    filename = Path(filename).resolve()
    data = json.loads(filename.read_text(encoding="utf-8"))
    if data.get("version") != 1:
        raise ValueError("Expected dataset version 1")
    references, queries = data["references"], data["queries"]
    if not references or not queries:
        raise ValueError("References and held-out queries are required")
    ids, hashes, sessions = set(), {}, {"references": set(), "queries": set()}
    for split, entries in (("references", references), ("queries", queries)):
        for entry in entries:
            for key in ("id", "session", "floor", "path"):
                if not isinstance(entry.get(key), str) or not entry[key].strip():
                    raise ValueError(f"Missing {key}")
            if entry["id"] in ids:
                raise ValueError("Duplicate image ID")
            ids.add(entry["id"])
            sessions[split].add(entry["session"])
            if split == "references" and not entry.get("identity"):
                raise ValueError("References require landmark identity")
            if split == "queries" and "identity" not in entry:
                raise ValueError("Query identity must be a label or null for a negative")
            if entry.get("identity") is not None and (
                not isinstance(entry["identity"], str) or not entry["identity"].strip()
            ):
                raise ValueError("Invalid identity")
            image = (filename.parent / entry["path"]).resolve()
            if not image.is_relative_to(filename.parent):
                raise ValueError("Image paths must stay inside the dataset directory")
            digest = hashlib.sha256(image.read_bytes()).hexdigest()
            if digest in hashes and hashes[digest] != split:
                raise ValueError("Image leakage across reference/query split")
            hashes[digest] = split
            entry["absolute_path"] = str(image)
            entry["sha256"] = digest
    if sessions["references"] & sessions["queries"]:
        raise ValueError("Capture sessions must be held out in full")
    return data


def prepare_dataset(project_directory, session):
    """Read existing exported project assets without modifying the manifest."""
    root = Path(project_directory).resolve()
    project = json.loads((root / "project.json").read_text(encoding="utf-8"))
    if project.get("version") not in (2, 3, 4, 5, 6):
        raise ValueError("Expected a mapper project with panorama labels (versions 2-6)")
    references = []
    for centre in project["capture_centres"]:
        for panorama in centre["panoramas"]:
            for label in panorama.get("labels", []):
                identity = ("feature:" + label["feature_id"] if label.get("feature_id")
                            else "label:" + label["id"])
                views = [(label["id"], label["reference_path"])]
                views += [(photo["id"], photo["reference_path"]) for photo in label.get("photos", [])]
                for view_id, relative in views:
                    image = (root / relative).resolve()
                    if not image.is_relative_to(root) or not image.is_file():
                        raise ValueError("Missing reference or invalid project asset path")
                    references.append({"id": view_id, "path": image.relative_to(root).as_posix(),
                                       "identity": identity, "floor": centre["floor"],
                                       "session": session, "centre_id": centre["id"]})
    if not references:
        raise ValueError("Project has no labeled reference images")
    return {"version": 1, "references": references, "queries": []}


class Matcher:
    def __init__(self, method, device="cpu", max_keypoints=1400):
        self.method = method
        self.device = device
        self.max_keypoints = max_keypoints
        if method == "aliked-lightglue":
            import torch
            from lightglue import ALIKED, LightGlue
            self.torch = torch
            self.extractor = ALIKED(max_num_keypoints=max_keypoints).eval().to(device)
            self.matcher = LightGlue(features="aliked").eval().to(device)
        elif method in ("orb", "sift"):
            self.extractor = (cv2.ORB_create(max_keypoints, fastThreshold=12)
                              if method == "orb" else cv2.SIFT_create(max_keypoints))
            self.matcher = cv2.BFMatcher(cv2.NORM_HAMMING if method == "orb" else cv2.NORM_L2)
        else:
            raise ValueError(f"Unknown matcher: {method}")

    def sync(self):
        if self.method == "aliked-lightglue" and self.device.startswith("cuda"):
            self.torch.cuda.synchronize()

    def extract(self, filename):
        # No resizing or EXIF auto-rotation: pixel coordinates remain explicit.
        image = cv2.imread(str(filename), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
        if image is None:
            raise ValueError(f"Unreadable image: {filename}")
        height, width = image.shape[:2]
        if self.method == "aliked-lightglue":
            tensor = self.torch.from_numpy(
                cv2.cvtColor(image, cv2.COLOR_BGR2RGB).transpose(2, 0, 1).copy()
            ).float().to(self.device) / 255
            with self.torch.inference_mode():
                features = self.extractor.extract(tensor, resize=None)
        else:
            features = self.extractor.detectAndCompute(cv2.cvtColor(image, cv2.COLOR_BGR2GRAY), None)
        return features, (width, height)

    def correspondences(self, reference, query):
        a, b = reference[0], query[0]
        if self.method == "aliked-lightglue":
            with self.torch.inference_mode():
                pairs = self.matcher({"image0": a, "image1": b})["matches"][0]
            return (a["keypoints"][0][pairs[:, 0]].cpu().numpy(),
                    b["keypoints"][0][pairs[:, 1]].cpu().numpy())
        if a[1] is None or b[1] is None or len(b[0]) < 2:
            return np.empty((0, 2)), np.empty((0, 2))
        pairs = [m for pair in self.matcher.knnMatch(a[1], b[1], k=2)
                 if len(pair) == 2 for m, n in [pair] if m.distance < .75 * n.distance]
        return (np.array([a[0][m.queryIdx].pt for m in pairs]).reshape(-1, 2),
                np.array([b[0][m.trainIdx].pt for m in pairs]).reshape(-1, 2))


def verify_pair(source, target, reference_size, query_size):
    result = {"matches": len(source), "inliers": 0, "inlier_ratio": 0.,
              "query_coverage": 0., "reference_coverage": 0., "reason": "few_correspondences"}
    if len(source) < 16:
        return result
    h, mask = cv2.findHomography(source, target, cv2.RANSAC, 3.)
    if h is None or mask is None or not np.isfinite(h).all():
        result["reason"] = "homography_failed"
        return result
    selected = mask.ravel().astype(bool)
    count = int(selected.sum())
    result.update(inliers=count, inlier_ratio=count / len(source))
    for name, points, size in (("reference", source, reference_size), ("query", target, query_size)):
        area = cv2.contourArea(cv2.convexHull(points[selected].astype(np.float32))) if count >= 3 else 0.
        result[f"{name}_coverage"] = area / (size[0] * size[1])
    result["reason"] = ("verified" if count >= 12 and result["inlier_ratio"] >= .45
                        and min(result["query_coverage"], result["reference_coverage"]) >= .02
                        else "insufficient_geometric_support")
    return result


def choose_candidate(attempts):
    # Multiple photos of one landmark do not create independent votes.
    best = {}
    for attempt in attempts:
        if attempt["reason"] != "verified":
            continue
        key = (attempt["floor"], attempt["identity"])
        score = attempt["inliers"] * attempt["inlier_ratio"]
        if key not in best or score > best[key][0]:
            best[key] = (score, attempt)
    ordered = sorted(best.values(), key=lambda row: row[0], reverse=True)
    if not ordered:
        return None, "no_verified_candidate"
    if len(ordered) > 1 and ordered[1][0] >= ordered[0][0] * .8:
        return None, "competing_candidates"
    return ordered[0][1], "accepted_appearance_only"


def benchmark(dataset, methods, device, output):
    data = load_dataset(dataset)
    output = Path(output)
    if output.exists():
        raise ValueError("Output already exists; use a new report path")
    with output.open("x", encoding="utf-8") as stream:
        def emit(row):
            stream.write(json.dumps(row, allow_nan=False) + "\n")
            stream.flush()
        emit({"event": "configuration", "version": 1, "device": device,
              "python": platform.python_version(), "opencv": cv2.__version__,
              "numpy": np.__version__, "methods": methods,
              "dataset_sha256": hashlib.sha256(Path(dataset).read_bytes()).hexdigest(),
              "policy": "experimental-appearance-v1", "navigation_authority": False})
        for method in methods:
            start = time.perf_counter()
            try:
                engine = Matcher(method, device)
            except Exception as error:
                emit({"event": "model_error", "method": method, "error": str(error)})
                raise
            engine.sync()
            provenance = {}
            if method == "aliked-lightglue":
                provenance = {"torch": engine.torch.__version__,
                              "lightglue": importlib.metadata.version("lightglue"),
                              "installation": json.loads(importlib.metadata.distribution("lightglue").read_text("direct_url.json") or "null"),
                              "weights": {}}
                cache = Path(engine.torch.hub.get_dir()) / "checkpoints"
                for weight in sorted(cache.glob("*.pth")):
                    if "aliked" in weight.name.lower() or "lightglue" in weight.name.lower():
                        provenance["weights"][weight.name] = hashlib.sha256(weight.read_bytes()).hexdigest()
                if device.startswith("cuda"):
                    provenance["device_name"] = engine.torch.cuda.get_device_name()
                    engine.torch.cuda.reset_peak_memory_stats()
            emit({"event": "model_loaded", "method": method,
                  "initialization_ms": (time.perf_counter() - start) * 1000,
                  "max_keypoints": engine.max_keypoints, "provenance": provenance})
            references = []
            for ref in data["references"]:
                references.append((ref, engine.extract(ref["absolute_path"])))
            engine.sync()
            correct = false_accepts = wrong_floors = accepted = 0
            latencies = []
            for query in data["queries"]:
                engine.sync()
                start = time.perf_counter()
                features = engine.extract(query["absolute_path"])
                attempts = []
                for ref, ref_features in references:
                    pair_start = time.perf_counter()
                    source, target = engine.correspondences(ref_features, features)
                    result = verify_pair(source, target, ref_features[1], features[1])
                    engine.sync()
                    result.update(reference_id=ref["id"], identity=ref["identity"], floor=ref["floor"],
                                  pair_ms=(time.perf_counter() - pair_start) * 1000)
                    attempts.append(result)
                winner, reason = choose_candidate(attempts)
                elapsed = (time.perf_counter() - start) * 1000
                latencies.append(elapsed)
                prediction = None if winner is None else {k: winner[k] for k in ("identity", "floor")}
                expected = None if query["identity"] is None else {"identity": query["identity"], "floor": query["floor"]}
                correct += prediction == expected
                accepted += prediction is not None
                false_accepts += prediction is not None and prediction != expected
                wrong_floors += prediction is not None and prediction["floor"] != query["floor"]
                emit({"event": "query", "method": method, "query_id": query["id"],
                      "session": query["session"], "expected": expected, "prediction": prediction,
                      "reason": reason, "elapsed_ms": elapsed, "attempts": attempts})
            emit({"event": "summary", "method": method, "queries": len(latencies),
                  "correct": correct, "accepted": accepted, "false_accepts": false_accepts,
                  "wrong_floor_accepts": wrong_floors,
                  "peak_cuda_allocated_bytes": (engine.torch.cuda.max_memory_allocated()
                      if method == "aliked-lightglue" and device.startswith("cuda") else None),
                  "latency_p50_ms": float(np.percentile(latencies, 50)),
                  "latency_p95_ms": float(np.percentile(latencies, 95))})
            del engine, references


def estimate_pose(data):
    """PnP in reconstruction coordinates, then explicit Sim(3) to east/north/up.

    Input observations must come from a real reconstructed 3D map. Descriptor
    matching/track association is upstream; landmark names cannot substitute.
    """
    points = np.asarray(data["points3d"], dtype=np.float64)
    pixels = np.asarray(data["pixels"], dtype=np.float64)
    if points.ndim != 2 or points.shape[1] != 3 or len(points) < 8:
        raise ValueError("At least eight 2D-3D correspondences required")
    finite_array(points, (len(points), 3), "points3d")
    finite_array(pixels, (len(points), 2), "pixels")
    if len(np.unique(points, axis=0)) != len(points) or len(np.unique(pixels, axis=0)) != len(points):
        raise ValueError("Duplicate 2D-3D observations")
    width, height = finite_array(data["image_size"], (2,), "image_size")
    if min(width, height) <= 0 or np.any(pixels < 0) or np.any(pixels >= [width, height]):
        raise ValueError("Observations outside calibrated image")
    k = finite_array(data["intrinsics"], (3, 3), "intrinsics")
    if k[0, 0] <= 0 or k[1, 1] <= 0 or not np.allclose(k[2], [0, 0, 1]) or k[0, 1] != 0 or k[1, 0] != 0:
        raise ValueError("Expected pinhole camera matrix")
    distortion = np.asarray(data.get("distortion", [0., 0., 0., 0.]), dtype=np.float64)
    if distortion.ndim != 1 or len(distortion) not in (4, 5, 8, 12, 14) or not np.isfinite(distortion).all():
        raise ValueError("Invalid OpenCV distortion coefficients")
    alignment = data["alignment"]
    rotation = finite_array(alignment["rotation"], (3, 3), "alignment rotation")
    translation = finite_array(alignment["translation_metres"], (3,), "alignment translation")
    scale = float(alignment["metres_per_unit"])
    if not np.allclose(rotation.T @ rotation, np.eye(3), atol=1e-6) or not np.isclose(np.linalg.det(rotation), 1):
        raise ValueError("Alignment must be a proper rotation")
    if not math.isfinite(scale) or scale <= 0 or not alignment.get("id") or not data.get("floor") or not data.get("map_id"):
        raise ValueError("Explicit metric scale, map, alignment ID and floor required")
    timestamp = data["timestamp_ms"]
    if isinstance(timestamp, bool) or not isinstance(timestamp, int) or timestamp < 0:
        raise ValueError("Invalid capture timestamp")
    base = {"event": "pose", "map_id": data["map_id"], "floor": data["floor"],
            "alignment_id": alignment["id"], "timestamp_ms": timestamp,
            "navigation_authority": False, "uncertainty_metres": None,
            "heading_uncertainty_degrees": None, "depth_provenance": None,
            "route_edge": None, "route_progress": None,
            "policy": "experimental-pnp-v1"}
    # Degenerate geometry cannot establish a robust 3D hypothesis here.
    singular = np.linalg.svd(points - points.mean(axis=0), compute_uv=False)
    if singular[-1] < singular[0] * 1e-3:
        return dict(base, accepted=False, reason="degenerate_3d_support")
    ok, rvec, tvec, inliers = cv2.solvePnPRansac(
        points, pixels, k, distortion, iterationsCount=1000,
        reprojectionError=3., confidence=.999, flags=cv2.SOLVEPNP_EPNP)
    if not ok or inliers is None or len(inliers) < 8 or len(inliers) / len(points) < .5:
        return dict(base, accepted=False, reason="insufficient_pnp_inliers")
    selected = inliers.ravel()
    support = np.linalg.svd(points[selected] - points[selected].mean(axis=0), compute_uv=False)
    if support[-1] < support[0] * 1e-3:
        return dict(base, accepted=False, reason="degenerate_inlier_support")
    rvec, tvec = cv2.solvePnPRefineLM(points[selected], pixels[selected], k, distortion, rvec, tvec)
    camera_rotation = cv2.Rodrigues(rvec)[0]
    projected = cv2.projectPoints(points[selected], rvec, tvec, k, distortion)[0].reshape(-1, 2)
    errors = np.linalg.norm(projected - pixels[selected], axis=1)
    coverage = cv2.contourArea(cv2.convexHull(pixels[selected].astype(np.float32))) / (width * height)
    camera_points = (camera_rotation @ points[selected].T).T + tvec.ravel()
    if not np.isfinite(errors).all() or np.max(errors) > 3 or coverage < .02 or np.any(camera_points[:, 2] <= 0):
        return dict(base, accepted=False, reason="poor_reprojection_or_spatial_support")
    centre = -camera_rotation.T @ tvec.ravel()
    position = scale * rotation @ centre + translation
    forward = rotation @ camera_rotation.T @ np.array([0., 0., 1.])
    if np.linalg.norm(forward[:2]) < .1:
        return dict(base, accepted=False, reason="heading_unobservable")
    return dict(base, accepted=True, reason="geometric_hypothesis_only",
                position_enu_metres=position.tolist(),
                heading_degrees=math.degrees(math.atan2(forward[0], forward[1])) % 360,
                inliers=len(selected), correspondences=len(points),
                reprojection_rmse_px=float(np.sqrt(np.mean(errors ** 2))),
                image_coverage=coverage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    match = sub.add_parser("benchmark")
    match.add_argument("dataset", type=Path)
    match.add_argument("--methods", nargs="+", choices=["orb", "sift", "aliked-lightglue"],
                       default=["orb", "sift", "aliked-lightglue"])
    match.add_argument("--device", default="cpu", choices=["cpu", "cuda"])
    match.add_argument("--output", type=Path, required=True)
    pose = sub.add_parser("pose")
    pose.add_argument("observations", type=Path)
    prepare = sub.add_parser("prepare-dataset")
    prepare.add_argument("project_directory", type=Path)
    prepare.add_argument("--session", required=True)
    args = parser.parse_args()
    try:
        if args.command == "benchmark":
            benchmark(args.dataset, args.methods, args.device, args.output)
        elif args.command == "pose":
            print(json.dumps(estimate_pose(json.loads(args.observations.read_text(encoding="utf-8"))), allow_nan=False))
        else:
            print(json.dumps(prepare_dataset(args.project_directory, args.session), indent=2))
    except (ValueError, KeyError, OSError, ImportError, RuntimeError, cv2.error) as error:
        parser.exit(2, f"Vision experiment failed: {error}\n")


if __name__ == "__main__":
    main()
