# Development notes

## November 24, 2026

- Defined the exercise around two marked frames and a find–lose–recover movement. The iPhone camera has one job during setup: anchor a virtual head on the table. The blade camera has a separate job during practice: estimate the physical blade position relative to the head's reference.
- Added a SwiftUI recorded exercise with a synthetic fixture. The learner marks two frames, answers both sets of questions, reviews both reference frames, then retries. The first simulator walkthrough passed. Unit checks covered a sustained loss and partial return, flicker, tracking dropout, invalid motion, and item-level landmark results.
- Added an ARKit table-placement prototype using an original geometric stand-in. The recorded exercise and placement prototype can be built together. Live tabletop registration, the final anatomical model, blade pose, and Firebase inference need their own verification.
- Started device verification of the separate signed recording-free research preview. The build installed and launched on the paired physical iPhone using the research staging app. The live folder had 12 entries before installation and after launch, with no new, removed or changed entries. Blade motion and disconnect behavior still need observation.
- Published the standalone trainer under Apache 2.0 with a two-commit implementation history and this build log. The recorded exercise uses synthetic inputs so contributors can try it without hardware.
- Added a consent-gated Firebase adapter with a reviewed-text allowlist and a deterministic answer card. The Firebase variant compiled against SDK 12.19.3. App Check and both inference routes still need a configured research project and a device run.

### Live blade preview verified

Andrew checked the separate signed research preview on a physical iPhone with an IntuBlade connected. Two different objects appeared live as he moved the blade, and the image cleared when he unplugged it. After the check, the preview's recording folder had the same 12 top-level entries and the same metadata as before. The check used folder metadata only. Tabletop pose tracking and the 24-sweep carton test still await bench verification.

### Standalone iPhone install

Signed the standalone trainer from commit c63a2ca, installed it on a physical iPhone, and launched it successfully. Table placement and the first on-phone recorded rep await a hands-on walkthrough.

### From a frame slider to a moving camera

- Replaced the sphere-based placement head with a shaped, textured USDZ shell on a training base. The original generated facial texture and modeled exterior serve AR setup. The internal teaching anatomy still needs independent authorship and educator review. [Rendered head](Artwork/head-preview.png)
- Added an eight-second, programmed camera path through a schematic airway after placement. The virtual lens advances, turns away and returns. The separate scored example now plays while the learner marks two moments.
- Added a square-marker pose solver that accepts ordered, undistorted corners and a measured marker width. A second transform expresses camera pose relative to the mouth. Test inputs cover a tilted square, coordinate registration, missing input, mirrored calibration and distorted corners.
- Six core tests passed. The simulator completed the playback, marking, labeling and reveal workflow. The updated standalone application launched on a physical iPhone. The physical blade has yet to drive the renderer. The next integration needs calibrated blade frames, marker identification and a measured mouth-to-target transform. The 24-sweep test remains pending.

### Standalone blade feed and relative camera motion

Connected the accessory callback to an in-memory QR detector and the virtual camera. The starting pose is user-selected. A missing marker or stale pose clears the view. A shifted digital marker changed the computed camera position, and a blank frame produced no pose. Seven core tests passed. Physical motion remains an operator check.

The first blade-enabled install crashed on launch. The iPhone crash report located the fault in SDK startup. The build lacked version metadata. Adding release and build versions restored startup on the same phone. The app now checks for both fields before starting the SDK.

Reworked the setup head’s brow, cheeks and mouth relief and applied a newly generated face texture. The private build can load a separate authorized airway mesh. The next milestones are measured blade optics, shared mouth registration, target visibility across the full movement, and educator-reviewed landmark and POGO reference views.
