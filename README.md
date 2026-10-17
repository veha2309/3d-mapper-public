# 3D Mapper

Flutter application for Windows map annotation and panorama capture planning,
with Android offline project review and landmark camera recognition.

## Features

- Import GeoJSON floor plans and inspect annotations in 2D or a height-based 3D view.
- Add landmarks, polygons, capture centres, and reference photos.
- Attach stitched equirectangular panoramas and label visible landmarks.
- Draw, edit, and review paths; preview turns, distances, and arrival wording.
- Transfer projects as portable `.mapper` bundles.
- Test Android landmark recognition with ALIKED + LightGlue or ORB/SIFT.

Route distances come from map coordinates. Recognition identifies visible labels;
it does not measure live phone pose or confirm arrival. Automatic live navigation,
structure from motion, depth reconstruction, and mesh generation are not implemented.

## Source-only distribution

Maps, photos, sample projects, synthetic panoramas, test suites and datasets,
field reports, capture archives, build output, and local settings are excluded.
The example-project action is removed because its sample assets are not shipped.
Bring your own authorized GeoJSON and panorama images. Pretrained inference models
and third-party license notices remain under
`android/app/src/main/assets/vision/`.

## Requirements

- Flutter SDK compatible with Dart 3.13.4 or newer.
- For Windows: Visual Studio 2022 with **Desktop development with C++**.
- For Android: Android SDK/JDK and a physical device for camera trials.

## Run and build

From the repository root:

```powershell
flutter pub get
flutter run -d windows
# Or select a connected Android device:
flutter devices
flutter run -d <android-device-id>
```

```powershell
flutter analyze
flutter build windows --release
flutter build apk --debug
```

Distribute the complete Windows build folder, including DLLs and `data/`.
Release Android signing requires your own configuration. Tests and datasets are
intentionally omitted. This sanitized source export has not been rebuilt or
physically validated.

## Mapping workflow

1. On Windows, choose **Import map** and select your own GeoJSON or provider JSON.
2. Select a floor, edit annotations, and place capture centres or review a grid.
3. Attach exported 360-degree JPGs to centres and set their heading manually.
4. Open **Path editor**, draw points and bends, and review actual walkability.
   Shared vertices connect routes; crossing lines alone do not create junctions.
5. Use **Route preview** to rehearse turns and orientation descriptions.
6. Export a `.mapper` bundle and import it on Android for offline review,
   landmark photo authoring, and **Test camera recognition**.

Supported maps use WGS84 `[longitude, latitude]` coordinates in a GeoJSON
`FeatureCollection` or the provider's `{"data": [...]}` wrapper. Point, Polygon,
and LineString features are supported. Floor comes from `floor`, then `level`.
Small-area metric projection is intended for individual buildings. Source map
properties are preserved; edits are stored as overlays.

Panoramas must be stitched equirectangular JPG/JPEG images, approximately 2:1.
Raw Insta360 `.insp`/`.insv` files are not supported. Assign physical capture
positions and headings yourself; image import does not establish geolocation.

## Portable projects and storage

Projects live in the platform application-support directory, with a `project.json`
manifest, original `source.json`, panoramas, and recognition references. A `.mapper`
file packages referenced assets in a ZIP for transfer. Exported files do not update
when the local project changes. Current format version 6 reads versions 1-5;
older applications cannot read newly saved version-6 projects.

The bundle workflow limits compressed/expanded projects to 512 MiB, individual
JPGs to 128 MiB, and map/manifest files to 16 MiB. Split large surveys into projects.
The admin entry enables local authoring; it does not implement account roles.

## Repository layout

- `lib/`: UI, map models, project storage, path editing, and route previews.
- `android/`: Android host and native offline vision integration.
- `windows/`: Windows desktop runner.
- `shaders/`: panorama rendering shader.
- `tools/vision/`: model export and vision pipeline tools.

Model licenses and runtime notices are included alongside the bundled model files.
