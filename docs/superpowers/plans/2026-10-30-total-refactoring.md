# Total Refactoring — Lens Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Raise the codebase to deploy-grade quality across 8 axes (clean architecture, performance, validation, error handling, naming, DRY structure, motion, unified black-minimalist UI) while keeping all 406 tests green and `flutter analyze` clean.

**Architecture:** Behavior-preserving refactor on top of the existing feature-first layout. Three new cross-cutting layers: `shared/diagnostics` (logging + global error surface), `shared/widgets` consolidation (badge, chip, icon-button, panel pieces), and a de-duplicated `EditorStateNotifier` commit core. The CPU imaging pipeline keeps its stage contract but loses per-pixel allocations, O(n·r) blur regression, and UI-isolate work.

**Tech Stack:** Flutter 3.38 / Dart 3.13, Riverpod 3, package:image 4.12, ML Kit selfie segmentation. No new dependencies.

**Spec:** User brief (8 standards) + three audit reports (error handling, UI duplication, imaging performance), summarized inline per task.

## Global Constraints

- Baseline: `flutter analyze` → 0 issues; `flutter test` → 406 passing. Both must hold after **every** task.
- No new packages. Dart SDK ^3.13.5. No git in this workspace — verification is tests, not commits.
- Behavior contracts documented in code (undo-depth emission, stroke bracketing, cache keys, shader/CPU grade parity) are load-bearing: changes must preserve them or update the doc comment in the same edit.
- Black-minimalist style: colors only via `AppColors` (context.themeColors), radii via `AppRadius`, spacing via `AppSpacing`/`EditorPanelMetrics`. No new hex literals in features.
- One-off motion durations explicitly audited as off-token (see `app_durations.dart`) stay off-token.

## Review Focus

- Picker-cancel on Android must not show "Could not open the photo" (Task 2 test: cancel path returns silently).
- A failed preview/square decode must never serve the full-resolution original as a "preview" (Task 2 test: failure → null contract).
- Cache settles on error must still fire `onReady` hooks, or the blur auto→manual handoff hangs (Task 2 test).
- Slider drags must still cost exactly one undo entry, and depth-only commits must not re-emit (Task 3, existing `undo_hold_test`).
- Brush painting at long stroke lengths must not leak GPU textures (Task 2: explicit dispose of evicted `MaskManager` entries).

---

### Task 1: Diagnostics foundation (logging + global error surface)

**Files:**
- Create: `lib/shared/diagnostics/app_logger.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Produces: `abstract final class AppLogger` with `static void d/i/w/e(String message, {Object? error, StackTrace? stackTrace, String? context})`. Implementation: `dart:developer` `log` (DevTools-visible, cheap in release) + `debugPrint` when `kDebugMode`. Never throws.
- Produces: `void installGlobalErrorHandlers()` in main.dart — `FlutterError.onError` (log + `FlutterError.presentError`), `PlatformDispatcher.instance.onError` (log, return true), prefs bootstrap failure → log + `runApp` with a minimal in-material fallback screen instead of a white screen.
- Produces: memory-pressure hook in the root widget (`didHaveMemoryPressure`) → `PreviewCache.clear()`, `StructureCache.clear()`. `LutManager` is deliberately NOT cleared (atlases are bound in live fragment shaders; clearing mid-session breaks every on-screen preview — documented).

- [ ] Step 1: Implement `AppLogger` (levels, optional `context` tag, error + stack pass-through).
- [ ] Step 2: Wire `installGlobalErrorHandlers` + memory-pressure observer in `main.dart`; guard the `sharedPreferencesProvider.future` await.
- [ ] Step 3: Run `flutter analyze && flutter test` — both clean (existing `ui_crash_guards_test` covers boot).

### Task 2: Error-handling hardening (audit-driven bug fixes + logging at silent catches)

**Files (all Modify):** `library_screen.dart`, `device_gallery_provider.dart`, `preview_cache.dart`, `structure_cache.dart`, `enhance_cache.dart`, `blur_cache.dart`, `shader_preview.dart`, `lens_controller.dart`, `lut_manager.dart`, `export_screen.dart`, `save_service.dart`, `export_service.dart`, `collage_screen.dart`, `mask_manager.dart`.

Concrete fixes (from audit):
- `library_screen.dart:109` — import: catch picker-cancel `PlatformException` (codes `cancel`/`cancelled`) → silent debug log; other failures → log + snackbar; multi-select partial success message reports what was imported; codec lifecycle in `_open` wrapped in try/finally.
- `preview_cache.dart:79/216` — failure fallback returns **null** (caller decides), never the full-res original; `_downscale` probe decode replaced by `ui.ImageDescriptor.encoded(buffer)` (also removes a full-res decode); codec/frame lifecycles in try/finally.
- `blur_cache.dart:100` / `enhance_cache.dart:134` — fire `onReady` hooks on the error settle path (contract in class docs), log the failure.
- `shader_preview.dart:408-422` + `lut_manager.dart:170-180` — `decodeImageFromPixels` gets `onError:` → completer completes with error; callers catch, log, fall back to stub; failed futures are not memoized (`??=` on futures only after success).
- `export_screen.dart:82-85` — user-facing message from `ExportException.message`/`SaveException.message` (never raw `e.toString()`); also catch `Error` so `_running` can never stick; `_share` clears stale error first.
- `collage_screen.dart:209` — retry affordance keyed on `SaveException.denied` type, not `error.contains('Settings')`.
- `mask_manager.dart` — evicted `ui.Image` entries explicitly disposed (keep-last-generation policy); `_brushEntries` gets the same identity re-check `_floatEntries` has; drop `Uint8List.fromList` copy of fresh `encodePng` bytes.
- `device_gallery_provider.dart:180/236`, `structure_cache.dart:84`, `lens_controller.dart:31`, `save_service.dart`, `export_service.dart`, `shader_preview.dart:379/590/895` — log at debug/info; contracts unchanged.
- Never log per-frame/per-dab.

**Tests:** `device_gallery_test`, `save_service_test`, `filter_strip_test` must stay green. Add: preview-cache empty-bytes rejection test; mask-manager eviction-dispose unit test (fake image not feasible — assert no-throw + cache-bounded behavior via existing helpers if testable; otherwise cover by widget tests already present).

- [ ] Step 1: Fix + log each site above, keeping every documented never-throw contract.
- [ ] Step 2: `flutter analyze && flutter test` clean.

### Task 3: EditorStateNotifier de-duplication

**Files:** Modify `lib/features/editor/logic/editor_state.dart`.

**Interfaces:**
- Produces: `void _commitGrade(EditorState Function(EditorState) mutate)` — single implementation of the stroke-aware commit (early-return on whole-state equality; live-update inside an open stroke; else `_pushHistory` + depth emission). Replaces `_applyAdjust/_applyFilter/_applyEnhance/_applySelective/_applyBlur/_applyRays/_applyCrop` (7 copies).
- Produces: `static List<BrushStroke> _appendBrushPoint(List<BrushStroke> strokes, (double, double) point, {required bool extendLast, required double radius, required double feather})` — replaces the twin bodies of `addBrushPoint`/`addBlurBrushPoint`.
- Removes dead aliases `setRaysKind`/`setRaysType`/`setRaysDirection`/`setRaysSpread` (grep-verify zero usages first, tests included).

- [ ] Step 1: Grep for alias usages; delete if zero.
- [ ] Step 2: Introduce `_commitGrade` + `_appendBrushPoint`; rewrite the setters as one-liners.
- [ ] Step 3: `flutter test test/undo_hold_test.dart test/selective_state_test.dart test/enhance_ui_state_test.dart test/rays_panel_test.dart test/blur_panel_test.dart test/crop_stage_test.dart` + analyze.

### Task 4: Split the editor shell (god-file decomposition)

**Files:**
- Modify: `lib/features/editor/editor_screen.dart` (1428 → ~600 lines: shell, route warming, return-snapshot debounce, sheet measurement, layout builder).
- Create: `lib/features/editor/widgets/editor_chrome.dart` — `EditorFloatingPill`, `EditorUndoActions`, `EditorHistoryStepButton` (public, doc-marked internal; keys and semantics identical).
- Create: `lib/features/editor/widgets/editor_preview_area.dart` — `EditorPreviewArea` (was `_PreviewArea`); static `_pointerCount/_compareTimer` become instance fields (single instance in the tree).

**Constraints:** `ValueKey('blur-auto-miss')`, `'blur-fallback-manual'`, `'compare-hint'` keys preserved verbatim; the `_photoKey` GlobalKey hand-off and morph choreography untouched; all doc comments move with their code.

- [ ] Step 1: Extract chrome + preview area files with their docs.
- [ ] Step 2: `flutter test test/undo_hold_test.dart test/tool_rail_test.dart test/editor_preview_test.dart test/photo_viewport_test.dart test/gallery_flow_test.dart` + analyze.

### Task 5: CPU pipeline performance (audit findings 1–21, 28–32)

**Files:** Modify `lib/features/imaging/pipeline/lens_cpu.dart`, `lib/features/filters/lut_definition.dart`, `lib/features/adjust/cards/enhance/enhance_apply.dart`, `lib/features/rays/rays_math.dart`, `lib/features/imaging/structure/structure_filter.dart`, `lib/features/blur/subject_mask.dart`, `lib/features/selective/mask_raster.dart`, `lib/features/imaging/mask_manager.dart`.

Ordered sub-steps, each verified against the existing numeric tests:
- [ ] **5a** Extraction loops read `decoded.data` bytes directly (kill `Pixel`-getter `num` boxing), nested `for y / for x` loops replace flat `p % w / p ~/ w`, output written via one `Uint8List` + `Image.fromBytes` instead of `setPixelRgb`. Verify: `lens_cpu_test`, `lut_cpu_test` byte-exact.
- [ ] **5b** Blur stage: replace `img.gaussianBlur` (O(n·r), three extra full-frame copies) with a sliding-window 3-pass box blur directly on the float buffer, radius chosen to match the documented design; first verify shader-side bokeh in `lens_filter.frag`/`shader_preview.dart` and the blur tests' tolerances to keep CPU/GPU parity. Verify: `lens_cpu_test`, `blur_cpu_test`, `blur_pipeline_test`, `subject_mask_test`.
- [ ] **5c** Hoist loop-invariant math: negative-exposure `pow(2, -e)` and per-channel `pow` → 256-entry exp LUT (input is 8-bit-quantized at that stage); contrast: hoist `_tanh(conK)`, `1/t`; rays: single `atan2`, hoisted `pi/180` sector constants; structure: hoisted clamps. No value-changing LUTs where inputs are not quantized. Verify: `lens_cpu_test`, `rays_cpu_test`, `rays_math_test`, `structure_filter_test`.
- [ ] **5d** De-record hot per-pixel helpers (`LutTables.sampleLut`, `applyEnhancePixel`, `applyRaysPixel`): write results into preallocated scratch (isolate-local) instead of returning records. Verify: `lut_cpu_test`, `enhance_*_test`, `rays_cpu_test`.
- [ ] **5e** Subject-mask decode/resize/pack moves off the UI isolate (`Isolate.run`); ML Kit platform call stays on the root isolate. Verify: `subject_mask_test`, `blur_pipeline_test`.
- [ ] **5f** `mask_raster.dart` per-dab rebuild: keep O(n·m) rasterization but short-circuit unchanged strokes (reuse last raster when only appending and the hash matches); `featherBox` → sliding window. Verify: `selective_mask_test`, `selective_cpu_test`.

### Task 6: Shared UI kit — unify black-minimalist surfaces

**Files:**
- Create: `lib/shared/widgets/indicators/app_badge.dart` — `AppBadge({required Widget child, EdgeInsetsGeometry padding, double radius = AppRadius.xs})`: surface fill + hairline border. Replaces the compare-hint, "Original" badge, blur-auto-miss container (identical decoration twins in editor screens).
- Create: `lib/shared/widgets/inputs/app_choice_chip.dart` — `AppChoiceChip({required String label, required bool selected, required VoidCallback onTap})`: unified radius `AppRadius.sm`, selected fill `surfaceBright` + `primary` text, `PressableScale` feedback. Replaces `_RatioChip` (crop), `_Choice` (settings), and the `ChoiceChip` wraps (collage) — unifying radius 10→12 and gesture wrappers.
- Modify: `lib/shared/widgets/buttons/app_button.dart` — add `AppButton.iconGhost({icon, tooltip, semanticLabel, onTap, size = 40, minHeight = 44})` factory collapsing the 9 duplicated ghost-icon configs.
- Modify: `lib/shared/theme/app_text_styles.dart` — add `buttonSmall(context)` (14/w500/ls0); replaces the 7 duplicated `TextStyle(fontSize: 14, fontWeight: w500, letterSpacing: 0)` literals.
- Create: `lib/features/editor/widgets/tool_panel_pieces.dart` — `ToolPanelHint` (hint text row, 3 copies) + `ToolActivateButton` (one-tap primary CTA, 2 copies).
- Modify consumers: `crop_panel.dart`, `settings_screen.dart`, `collage_screen.dart`, `export_screen.dart`, `editor_screen.dart`, `editor_chrome.dart`, `blur_panel.dart`, `rays_panel.dart`, `selective_panel.dart`, `library_screen.dart` (album strip + ghost buttons + text styles).

- [ ] Step 1: Build the four shared pieces + two tokens.
- [ ] Step 2: Migrate consumers; delete the private twins.
- [ ] Step 3: `flutter analyze && flutter test` (carousel/panel/crop/settings/collage tests).

### Task 7: Card structure consolidation (19 folders → per-feature card files)

**Files:**
- Modify: `lib/features/adjust/cards/adjust_cards.dart` (absorbs the 8 pure-config cards + keeps `EnhanceCard`); delete `adjust/cards/<param>/` folders.
- Modify: `lib/features/blur/cards/blur_cards.dart` (absorbs Radius/Feather); delete folders.
- Modify: `lib/features/rays/cards/rays_cards.dart` (absorbs the 6 pure-config cards; ModeCard keeps its file if it has behavior — verify first); delete folders.
- Modify: `lib/features/selective/cards/selective_cards.dart` (absorbs the 3 grade cards); delete folders.
- Modify: `lib/features/editor/logic/tool_card.dart` — add `abstract class SliderValueCard extends ToolCard` (the shared `showSliderLabel/showSliderValue/alwaysShowValue => true` preset) replacing the byte-identical `BlurCard`/`RaysCard` bases.

**Constraint:** class names, `id`s, labels, keys, and card order preserved (tests reference them); the per-folder growth path documented in `tool_card.dart` is replaced by an updated doc note (a card graduates from a data-style class to its own file when it grows real UI).

- [ ] Step 1: Consolidate + delete folders + update imports (incl. tests).
- [ ] Step 2: `flutter analyze && flutter test` full suite.

### Task 8: Strict-lint pass + structure docs

**Files:** Modify `analysis_options.yaml`, `README.md` (structure section), plus any files the new lints flag.

- [ ] Step 1: Add curated rules (e.g. `directives_ordering`, `prefer_const_constructors`, `unnecessary_lambdas`, `use_super_parameters`, `unawaited_futures`, `avoid_print`, `no_runtimeType_toString`); run analyze; fix or justify each new violation; keep the set small enough to stay maintainable.
- [ ] Step 2: Full gate: `flutter analyze` (0 issues) + `flutter test` (406+ passing).

## Self-Review (weak spots found and fixed)

1. **Blur-stage rewrite risked CPU/GPU grade drift.** Swapping `img.gaussianBlur` for a box approximation changes exported pixels relative to the shader preview. Fix (Task 5b): read the shader bokeh + the blur tests' tolerances *before* choosing the kernel; box passes are variance-matched to the current radius, and the numeric tests gate parity. If tests encode gaussian-specific expectations, the fallback is an O(n) Deriche-style IIR gaussian — same complexity class, closer match.
2. **"Data-class ToolCards" would fight the documented per-folder growth design and break test imports.** Fix (Task 7): consolidation keeps real classes with identical names/ids (so `ToolCard`'s extension contract and all tests stay intact); it removes only the folder-per-38-line-file ceremony, and updates the design doc note. Cards with behavior (Enhance, possibly Mode) keep their own files.
3. **Logging everywhere risks per-frame log spam and release-mode noise.** Fix (Tasks 1–2): level-gated `AppLogger` on `dart:developer` `log` (near-zero cost in release), explicit "never log per-frame/per-dab" rule, and silent catches stay silent-but-observable (debug/info) while error paths log with the error object + stack.
