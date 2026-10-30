# Lens

Lens is a Flutter photo editor built around a fast, shader-driven editing flow. The GPU renders the live preview through one GLSL fragment shader, and a Dart CPU pipeline re-applies the same grade at full export resolution, so the saved photo matches the preview.

## Features

- **Adjust**: exposure, contrast, structure, saturation, temperature, tint, shadows, highlights. The slider snaps to the neutral point of bipolar parameters.
- **Filters**: eight procedural LUT looks with per-filter strength. Every look is generated from code at runtime.
- **Enhance**: one-tap automatic grade (white balance, tone, vibrance) computed by a cached photo analysis in a background isolate.
- **Selective**: radial, linear and brush masks with local exposure, contrast and saturation.
- **Blur**: background bokeh driven by an ML Kit subject mask (auto) or a hand-painted brush (manual).
- **Rays**: Tyndall light shafts with a draggable sun.
- **Crop**: free and ratio-locked windows, straightening, quarter turns.
- **Collage**: combine 2 to 9 photos into a single rendered image.
- **History**: stroke-bracketed undo and redo. One entry per slider drag or discrete edit; tap a step to apply it once, hold the button to replay the whole history.
- **Compare**: press and hold the photo to view the original.
- **Performance-aware motion**: every animation passes through a central policy that adapts durations and blur effects to the selected quality profile and to the OS accessibility setting.

## Built With

- [Flutter](https://flutter.dev) (Material 3), Dart 3.13+
- [flutter_riverpod](https://pub.dev/packages/flutter_riverpod) for state management
- [google_mlkit_selfie_segmentation](https://pub.dev/packages/google_mlkit_selfie_segmentation) for the subject mask
- [image](https://pub.dev/packages/image) for the CPU export pipeline
- [gal](https://pub.dev/packages/gal), [share_plus](https://pub.dev/packages/share_plus), [photo_manager](https://pub.dev/packages/photo_manager), [image_picker](https://pub.dev/packages/image_picker) for saving, sharing and importing

## Getting Started

### Prerequisites

- Flutter SDK 3.38 or newer (`flutter --version` shows the exact build)
- An Android device or emulator for the full feature set. ML Kit requires Android; desktop targets grade photos with the manual brush as the documented fallback.

### Installation

```sh
git clone https://github.com/Hiw4i/Lens-app.git
cd Lens-app
flutter pub get
```

### Run

```sh
flutter run        # on a connected device or desktop target
```

The editor opens the gallery first. Device gallery access applies the photo_manager permission flow; the in-app picker imports photos directly.

## Testing

```sh
flutter test       # 406 unit and widget tests
flutter analyze    # strict lint set on top of flutter_lints
```

## Project Structure

```
lib/
  app/                  # router
  features/             # one folder per tool (adjust, blur, rays, ...)
    editor/             # the editing session: shell, chrome, preview area,
                        #   state and history (logic/), shared panels (widgets/)
    imaging/            # shader preview, CPU pipeline, caches, export
    <tool>/             # tool state and panels; cards/<tool>_cards.dart holds
                        #   the ordered parameter-card strip
  shared/
    data/               # preferences (typed keys + provider)
    diagnostics/        # AppLogger and the global error surface
    haptics/            # haptic feedback scopes
    motion/             # duration, curve and spring tokens + the performance
                        #   policy that gates every animation
    theme/              # AppColors palettes, text styles, radii and spacing
    widgets/            # AppButton, AppBadge, AppChoiceChip, press motion
shaders/                # lens_filter.frag (preview pipeline)
test/                   # unit and widget tests per feature
```

## Architecture Conventions

- **One visual system.** Colors come from `context.themeColors` (black minimalist surfaces, white and gray text), radii from `AppRadius`, spacing from `AppSpacing` and `EditorPanelMetrics`. Shared chrome lives in `shared/widgets`; features compose it.
- **Central motion policy.** `AppDurations` holds the duration scale, and `context.uiPerformance` scales it per quality profile. Per-widget one-off durations are documented exceptions listed in `app_durations.dart`.
- **Observable errors.** Cache and platform bridges keep their never-throw contracts; every failure path logs through `AppLogger` with the error object and stack trace. Global handlers in `main.dart` cover framework and unhandled async errors. Log volume stays off the per-frame path.
- **Single history path.** Every undoable edit goes through `EditorStateNotifier._commitGrade`, which produces exactly one history entry per drag or discrete edit.

## Roadmap

- iOS target for the ML Kit subject mask
- Localizations beyond English
- New editing tools and features
- Ongoing polish of the interface and of the existing tools

## License

The repository currently ships without a license. The author reserves all rights until a license file is added.

## Contact

Author: [Hiw4i](https://github.com/Hiw4i)
Project: https://github.com/Hiw4i/Lens-app
