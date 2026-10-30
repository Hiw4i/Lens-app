# Lens

A Flutter photo editor focused on a fast, shader-driven editing flow.

## Features

- **Adjust** — exposure, contrast, structure, saturation, temperature/tint, shadows, highlights.
- **Filters** — LUT-based looks with per-filter strength.
- **Enhance** — one-tap automatic grade (white balance, tone, vibrance) via cached photo analysis.
- **Selective** — radial / linear / brush masks with local exposure, contrast and saturation.
- **Blur** — background bokeh with an ML subject mask (auto) or manual brush.
- **Rays** — Tyndall light-shaft overlay with a draggable sun.
- **Crop** — free and ratio-locked window, straighten, quarter turns.
- **History** — stroke-bracketed undo/redo: one entry per slider drag or discrete edit; tap steps once, hold replays the whole history.
- Compare-hold (press the photo to see the original), haptics, performance-aware animation policy.

## Tech

- Flutter (Material 3), Riverpod for state.
- GLSL fragment shader (`shaders/lens_filter.frag`) for the live preview; a Dart CPU pipeline re-applies the same grade at export resolution.
- `google_mlkit_selfie_segmentation` for the subject mask (manual brush fallback on desktop / ML failure).

## Run

```sh
flutter pub get
flutter run        # on a connected device or desktop target
flutter test       # unit + widget tests
flutter analyze
```

The editor needs a photo: open the gallery (photo_manager permissions apply on device) or use the in-app picker.

## Structure

```
lib/
  app/                  # router
  features/             # one folder per tool (adjust, blur, rays, ...)
    editor/             # the editing session: shell, chrome, preview area,
                        #   state/history (logic/), shared panels (widgets/)
    imaging/            # shader preview, CPU pipeline, caches, export
    <tool>/             # tool state + panels; cards/<tool>_cards.dart holds
                        #   the ordered parameter-card strip
  shared/
    data/               # preferences (typed keys + provider)
    diagnostics/        # AppLogger + global error surface (main.dart wires it)
    haptics/            # haptic feedback scopes
    motion/             # duration/curve/spring tokens + the performance
                        #   policy that gates every animation
    theme/              # AppColors palettes, text styles, radii/spacing
    widgets/            # AppButton, AppBadge, AppChoiceChip, press motion
shaders/                # lens_filter.frag (preview pipeline)
test/                   # unit + widget tests per feature
```

### Conventions

- **One visual system.** Colors only via `context.themeColors` (black
  minimalist: near-black surfaces, white/gray text), radii via `AppRadius`,
  spacing via `AppSpacing`/`EditorPanelMetrics`. Shared chrome lives in
  `shared/widgets` — no hand-rolled badge/chip/button twins in features.
- **Motion is policy-gated.** Every animation duration passes through
  `context.uiPerformance` (`AppDurations` holds the scale; per-widget
  one-offs are explicitly audited there).
- **Errors are observable.** Never-throw contracts stay (caches, ML
  bridges), but every failure path logs through `AppLogger`; nothing is
  silently swallowed, and nothing logs per-frame. Global handlers are
  installed in `main.dart`.
- **History is stroke-bracketed.** Every undoable edit goes through
  `EditorStateNotifier._commitGrade` — one entry per drag or discrete edit.
# Lens-app
