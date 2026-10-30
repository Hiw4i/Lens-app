# Gallery, editor and collage implementation plan

> **For agentic workers:** Use executing-plans inline for the approved work.

**Goal:** Minimal device gallery, continuous photo transitions and working collage.
**Architecture:** Paged asset provider; shared photo Hero; adaptive editor;
shared collage geometry for Flutter preview and isolate rendering.
**Tech Stack:** Flutter, Riverpod, photo_manager, image, existing SaveService.
**Spec:** docs/superpowers/specs/2026-10-16-gallery-editor-design.md

## Constraints
Preserve existing palettes and processing pipeline. No bottom app navigation.
Respect reduced motion. No full-resolution decoding for gallery tiles.

## Review focus
Permission denial and limited access; cancelled/failed image loading; small
screens and large text; stale corrections between images; preview/export parity.

## Tasks
- [x] Add regression tests for fresh editor sessions and home navigation.
- [x] Gallery: paged assets, permissions, imports, loading/error/empty states,
  stable photo IDs and bounded thumbnails. Replace router tabs with home.
- [x] Transition/editor: predecode selected image, shared Hero in both directions,
  theme above Navigator, compact save/reset actions, responsive preview/controls.
- [x] Collage: test geometry and output pixels, implement 2–9 photo selection,
  ratio/grid/spacing controls, isolate render and gallery save.
- [x] Run flutter analyze, full flutter test, Android build and device inspection
  when a device is available. Review final changes, fix material issues once.

Verification: `flutter analyze`, `flutter test`, `flutter build apk --debug`.
Expected: analyzer clean, all tests pass, APK produced.

## Verification record
- `flutter test`: 111 tests passed, including source permission invalidation,
  navigation, collage export pixels, portrait/landscape and 2x text size.
- `flutter analyze`: no issues found.
- Release APK built; one Windows font file lock required a sequential rebuild.
- Native Android gallery and 2-photo collage preview inspected using a separate
  clean emulator data image in build/qa-emulator. Existing AVD data preserved.
- Review fixes: isolate old permission/page sessions, preserve the graded raster
  on Back, normalize unsupported native image codecs, scroll export/reset sheets,
  adapt history actions to large text, increase preset hit areas to 48 dp.
- UI/UX Pro Max used. GSAP Skills excluded per user's follow-up.
- No physical-device frame-time or HEIC camera fixture verification performed.
- Native collage save confirmed in MediaStore: JPEG, 1920 × 2400 (4:5).
- Native editor opened the saved collage with adaptive controls and preview.
