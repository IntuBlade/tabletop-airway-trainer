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

### Physical accessory connection check

The research iPhone reported one attached accessory. The SDK began connecting, then explicitly rejected the standalone app identity before delivering images. The live screen now shows SDK connection status, including identity rejection and accessory conflicts. Enabling the standalone identity requires vendor support. Marker tracking and the carton sweeps were not exercised in this check.

### Live blade frames in the research preview

Integrated the motion detector and airway renderer into the recording-free POGO preview that already has accessory access. The research iPhone reported an attached accessory and the app received live blade frames. Ten seconds later the on-phone detector acquired the trainer marker from that stream and set the starting pose. The preview displays the raw image until it acquires the screen marker, then switches to the virtual camera. Carton visibility and physical table registration remain separate checks.

Andrew confirmed on the physical iPhone that the live blade image switched to the airway and the view moved as he moved the blade. This verifies relative blade motion using the screen marker.

### Registered tabletop setup in Airway Practice

Installed and launched the standalone trainer with QR-referenced head placement and a registered virtual camera path. The camera pose now supports time-based smoothing of position and orientation. Missing measurements clear the filter, and reacquisition starts fresh. Nine tests passed, including coordinate-frame invariance and jitter/dropout behavior. Live movement at the placed mouth and the perceptual effect of smoothing still need physical verification after accessory access is provisioned for the trainer.

### Blade video during aiming

The staging trainer connected to the blade, but its aiming screen only displayed marker status. It now displays the latest SDK image until a usable registered pose is available and returns to the live image when marker tracking is lost. Disconnecting, leaving the preview, or a stale frame clears the image. Preview frames are held in memory. The signed fix installed and launched on the research iPhone.

### Registered-mouth withdrawal check

The operator registered the head and observed airway movement on centered entry and withdrawal. The model shook substantially and depth was hard to judge while backing out. This was a partial result. Depth accuracy and repeatable recovery remain unverified.

The next staging build filters QR corner observations across three frames before estimating pose, tightens the allowed geometric error as the marker shrinks, and keeps the airway scene loaded across tracking loss. It shows live blade video while reacquiring. A synthetic withdrawal test covers an isolated depth spike, continued motion, and loss. Ten core tests passed; the signed update installed and launched on the physical iPhone. Its effect on hand-held shake still needs an operator check. The carton test remains on hold.

### Place the mannequin through the blade camera

The operator reported that phone-camera placement did not match the intended device workflow. The blade-enabled build now uses a flat QR as the tabletop reference, intersects the blade crosshair with that plane, and displays the head over the live blade image. The airway view uses that same placement. Revised the mouth texture to remove the protruding incisors and checked the rendered model. Eleven core tests passed, including ray-to-plane placement and rejection of a camera pointing away. The signed build launched on the physical phone; blade-only placement and withdrawal accuracy await operator verification.

### Aligning the mouth to a flat QR

A physical setup attempt failed to line up. Setup had combined the newest blade image with an older filtered pose, and tapping picked a different point on the table depending on blade aim. The head now appears automatically with its nominal mouth above the QR center. Each setup overlay uses the same sensor pixels used for its pose. An outline identifies the decoded trainer QR, and the screen prompts the learner to back away when the mouth is outside the view.

Rendering the packaged head against a generated straight-on image of the published QR exposed a second error. Roughly one pixel of corner asymmetry tilted the estimated head enough to visibly displace the mouth. The tracker now favors a straight-on estimate when a rotated square fits the measured corners, blending into the perspective estimate as the square becomes foreshortened. The rendered mouth returned to the image center on that fixture. Twelve software tests passed. Physical alignment during approach and withdrawal still needs verification with the blade.
