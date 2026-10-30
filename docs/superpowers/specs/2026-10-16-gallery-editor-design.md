# Gallery, editor and collage

Approved in chat: minimal home with Edit and Collage actions, settings icon,
device photo gallery, no Library/Editor/Settings navigation. Tap a photo to
expand it seamlessly into the editor, reverse on back and retain scroll.
Editor prioritizes the photograph with adaptive controls, only working tools,
save in the header and reset in a secondary menu. Existing palettes remain.
Collage: select 2–9 images, choose grid and aspect ratio, adjust spacing, save.

Implementation decisions: Flutter native Android application (the existing
platform), photo_manager for paged device media and image_picker as fallback.
Permission denial/limited access remain actionable. Thumbnail grid never
loads all original bytes. Decode and precache the selected photograph before
navigation. Shared Hero uses a stable photo ID and a changing crop, destination
preview fits the photograph's real aspect ratio. Reduced motion is respected.
Collage geometry is shared by preview and isolate JPEG renderer; exports at
2400 px on the long edge. Theme is inherited above the Navigator.

No Git repository exists in this checkout; edits and validation happen in place.

Follow-up approved by user's screenshot: adjustment parameters are horizontal cards with a single shared slider; category navigation stays beneath the panel. Presets remain available from the slider's menu. Preserve palettes and the gallery/editor transition. Large-text compact layouts may scroll the control region while the parameter strip remains horizontal.
