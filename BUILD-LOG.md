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

### Checking a reported SDK identity rejection

The setup screen inferred identity rejection from free-text SDK messages. It now uses the connection callback and its structured error code. A recent unprocessed blade frame can supply the preview while QR detection is pending; overlays still use the image that produced the pose. The debug build can open directly to blade setup and log the first image delivery without saving that image.

On the research iPhone, the SDK reported a connected blade and delivered its first image to the open setup screen 42 milliseconds later. The existing 12 software tests passed. This run verifies delivery to the trainer. Physical mouth alignment through approach and withdrawal remains to be checked.

### A close blade could read the QR while the mouth was behind the lens

The nominal life-size mouth sits 135 mm above the paper. A simulated blade frame taken about 80 mm above a flat, centered marker reproduced the setup dead end. The new placement fits the entire exterior into the first usable blade view and holds that scale during the rep. The screen displays the scale, with explicit controls to refit or select life size. A smaller model changes physical travel, so it is a visual walkthrough. Setup and the interior use the same fixed scale.

The published QR and packaged mesh rendered together at 14% of life size in the 80 mm fixture. Thirteen software tests passed, including advance and withdrawal using one fixed scale. The staging build was installed and opened on the research phone. The reported app exit had no matching trainer crash report; its cause remains open. The renderer now reuses the decoded head and keeps the interior scene alive across short tracking losses. Live placement with this build still needs confirmation.

### Watching the transition on the research iPhone

On the mirrored phone, starting the previous rep immediately replaced the tabletop head with a small exterior view of the airway mesh. The updated trainer keeps the blade image and the head visible during approach. A tracked crossing of the nominal lip opening switches to the interior. Withdrawal past the lips restores the exterior, and tracking loss clears passage state. The opening dimensions are prototype model parameters.

Fourteen software tests passed. On the phone, starting practice at 9% scale kept the face over the QR. The head grew on approach and shrank on withdrawal. At close range the QR nearly filled the image. Switching to life size reproduced the reported outlined QR with no visible face at the same short working distance. The full exercise still needs a physical lip crossing with continuous tracking. No carton sweeps were run.

### Printing the tabletop marker at a known size

The QR PNG could be enlarged to fill the page in the print dialog. The pose solver assumes a 40 mm square, so an oversized print makes the blade appear closer to the page and can put the full-size virtual head behind the lens. The README now links a US Letter PDF with the original QR at 40 mm and a separate 40 mm ruler check. Apple Vision decoded the rendered sheet. Physical placement and mouth entry still need a pass with a correctly sized print.

### Starting a rep inside the mouth

Live practice now opens just past the simulated incisors as soon as the blade tracks the QR. The first pose anchors the starting view. In the research scene, physical forward and backward movement follows the bend from mouth to throat. Blade turns and sideways movement steer the view. If the QR leaves the frame, the trainer shows the blade feed and keeps the original reference for reacquisition. **Reset to teeth** uses the current tracked pose as a new start.

Thirteen software checks passed. The same camera code rendered the start, approach and throat on the local research mesh. Returning to the starting position produced the same rendered image. The signed build installed on the research iPhone. A locked phone and a Mirroring timeout prevented the live blade check.

### Testing blade shake before the next physical rep

A deterministic replay projects a 40 mm square, adds independent subpixel corner errors, and sends the observations through marker tracking, pose smoothing and the research camera path. A stationary feature 40 mm in front of the simulated lens measures apparent image motion in a 640 px wide view. The suite covers 15, 30 and 60 updates per second at three target angles from head-on to 34 degrees. These are simulated tracker rates.

At 30 updates per second and 20 degrees tilt, the old camera jumped 20.2 px per frame at the 95th percentile during a hold. Across all nine conditions, the worst 95th percentile went from 33.6 to 0.13 px after suppressing small corner changes before solving the camera pose. Comparison against the last accepted corners lets slow movement accumulate. A second filter responds faster to larger changes. An abrupt 20 mm withdrawal combined with a 12 degree turn reached 80% of both changes in 83–133 ms. A slow return was within 3 mm of the expected depth at its midpoint and endpoint.

The research renderer now uses a blade-mounted light with distance falloff and soft surface highlights. A local FFmpeg comparison shows both versions driven by identical synthetic input on the same private mesh. Fourteen software tests passed. The signed staging build installed on the research iPhone. Live stability, detector-to-display latency, frame pacing and the visual match to blade footage still need a physical check. The carton experiment remains on hold.

### Authoring the research airway material in Blender

Blender 4.2 unwrapped the research mesh and baked three 2048 × 2048 maps for tissue color, surface roughness and fine relief. Color variation is anchored to the surface and uses the original vertex colors. The iPhone renderer loads the authored material and uses a calibrated near-field light for it. Native renders at matching camera poses exposed overexposure and dark UV borders during development.

Compared the original and exported USD geometry arrays, including every vertex, face index and source normal. USD validation passed. The signed staging app contains the verified USDZ and installed on the research iPhone. All fourteen trainer software checks passed. The comparison frames and motion preview were rendered locally. Physical blade performance and the appearance relative to real blade footage still need review.

### Comparing the airway surface with clinical video

Reviewed the first two [University of Minnesota routine intubation videos](https://airway.umn.edu/node/126) at the tongue sweep, epiglottis and glottic opening. The two cameras show different color balances. In the first example at 26.14 seconds the fold margin is lighter and less red than adjacent tissue. The previous simulation reversed that local brightness relationship. The second example at 9.41 seconds shows streaks of deeper color across the epiglottis with small wet highlights.

The optional Blender region input uses the source mesh’s tissue labels and checks its hash, triangle indices and vertex colors before painting. The cord margin now has a muted ivory pigment, the pharynx warmer mucosa and the epiglottis a warmer edge. Neighboring vertex colors blend at boundaries. Fine color variation is fixed to the surface. Lower blade-light intensity and more fill preserve tissue detail on close approach.

At the same 70 mm simulated advance, the median fold-edge sample moved from 9 display levels darker than neighboring mucosa to 21 levels lighter. The first clinical example measured 17 levels lighter. These are manually matched 7 × 7 pixel samples using weighted RGB brightness on a 0–255 scale. At 21 mm advance the area with all three channels at or above 245 fell from 22% to under 0.1%. These comparisons guided authoring. They do not establish clinical accuracy or reproduce the IntuBlade camera’s white balance.

Fourteen software checks and USD validation passed. The signed staging app installed on the research iPhone with the verified model. The live appearance on the phone still needs review. The carton experiment remains on hold.

### Keeping the tongue from filling the view during a centered advance

Replayed the previous build through the middle of the practice rep. The blade camera approached the tongue closely enough to fill the frame and hide the landmarks. Sweeping the camera origin and its forward ray against the mesh every 0.1 mm through 70 mm of centered travel gave a minimum clearance of 1.31 mm and a minimum forward sightline of 2.54 mm. The revised guide gives 3.66 mm and 32.31 mm respectively. These figures describe this research mesh and a straight simulated advance. They do not measure physical tracking accuracy.

The Blender material gives the tongue fine surface relief and the epiglottis a smoother wet finish. The simulated blade illumination now fades down the deep airway. A local 121-frame native replay compares the two signed-build configurations at identical blade inputs through advance, turning away, recovery and withdrawal. The revised render returns pixel-for-pixel to its starting view and to its glottic view after the turn.

The [third university teaching clip](https://airway.umn.edu/node/126) shows an initially obscured opening, changes in tissue position with lift and pronounced loss of sharpness. The trainer still uses static geometry. Fourteen software checks and USD validation passed. The signed staging build with the verified asset installed on the research iPhone. The live blade rep and carton bench session were not run.

### Revealing the glottis with a tracked lift

The third [university clinical example](https://airway.umn.edu/node/126) shows a view changing with lift. The research renderer now deforms the epiglottis and adjacent tongue base when the virtual blade contact point rises near the mesh’s vallecula. The mesh supplies the direction and per-vertex lift weights. A smooth falloff confines movement to the pocket. The vocal folds have zero lift weight. Lowering the blade, leaving the pocket or losing tracking releases the deformation. The simulated blade contact offset and tissue excursion are provisional and do not measure force.

A 121-frame native replay exercised advance, lift, hold, release and withdrawal. A second render held the camera still while applying the same lift input. The opening was partly covered at rest, became visible under lift and returned to its starting appearance on release. Both replays returned pixel-for-pixel to their rest frames. An initial USD blend-shape export passed asset validation but rendered blank. The shipped version uses the textured mesh and interpolated vertex weights directly on the GPU.

All 16 software tests passed, including straight advance without lift, partial lift, off-center motion, withdrawal and loss of tracking. USD validation passed. The signed staging app installed on the research iPhone with the verified asset. A hands-on blade rep and educator review of the movement remain pending. The carton test remains on hold.

### Checking printed QR scale and recovery

Blade practice previously assumed a 40 mm black square for every print. A 160 mm square made a known 20 mm movement appear to be about 5 mm. Blade practice now accepts a measured black-square width, saves it locally and resets the tracking origin when it changes. The optional placed-head station retains its 40 mm image registration. When the video stops, the live screen shows the connection status. When video is present it distinguishes an absent QR from a detected QR awaiting tracking lock.

Two regression checks cover frontal and tilted projections plus rendered images of the shipped QR through the Apple barcode detector. In the image replay a 20 mm advance, interrupted by a blank frame, measured 20.7 mm with a 40 mm print and 19.1 mm with a 160 mm print. The larger print measured about 5 mm when replayed with the original assumption. All 18 tests passed. The verified staging build installed on the research iPhone. The replay uses nominal optics. Physical depth accuracy with the blade and a measured print still needs checking.

The live rep currently ends at finding and recovering the view. Marking both views, anatomical tagging and POGO review are available in the recorded exercise. Connecting those steps to the live simulated frames would let a learner review their own rep.

### Painting and moving the blade view in Blender

We gave the epiglottic rim, folds and tongue their own editable paint layers. At the same 2048-pixel atlas size, epiglottis detail increased from 5.57 to 15.25 texels per millimeter and vocal fold detail from 5.60 to 22.12. The rest of the surface went from 5.68 to 4.96. The tongue now uses relief baked from a 4,160-face Tissue patch. A control render used the same camera, mesh, lighting and paint with the previous procedural relief.

The partial lift now rolls the epiglottic rim and compresses the tongue base. The ActionPoser control drives three editable Blender shapes. The phone interpolates the corrective displacement and shading normals on the GPU. Retracting the blade returns the tissue to rest. A first export looked almost black because a second Blender material output took over the bake. An actual SceneKit render caught the error after USD validation passed.

Two 121-frame native replays, one with the lens held still and one with simulated blade motion, returned exactly to their initial frames. The clinical comparison still shows a sharper, brighter simulated epiglottic edge. The physical assembly audit also found a discrepancy between the design tip and the training contact point. The current rep uses a simulated contact point. Physical calibration and educator review remain open. Clinical reference: [University of Minnesota, third intubation example](https://airway.umn.edu/node/126).

All 18 software tests passed. The signed research build with the verified asset installed and launched on the iPhone. Hands-on performance of this revision has yet to be established.

### Registering the blade view and contact tip together

The previous guide placed the lens along one path and tested contact using a short virtual tip. We fitted a paired path against the research airway using the mechanical camera window and distal tip from the same source blade assembly. The entry pose starts the lens at the teeth. At the other end, the tip seats on the resting vallecula. The lens position follows from the same rigid offset used to drive tissue motion. The learner can turn away, lose contact and return.

The first candidate placed the tip inside the resting tissue. We traced the displaced surface and checked both ends of the blade through the approach. A 181-frame native replay showed the opening on lift, lost it on turning away and recovered the identical view on recentering. Release and withdrawal also returned to their matching frames. All 19 software tests passed. The signed standalone research update installed on the iPhone. The replay measures the authored path. Sensor roll, optical calibration, whole-blade clearance and hands-on performance remain open.

The public tooling binds a private profile to the exact airway export by hash. The blade measurements, engineering files and private airway stay in the research workspace.

### Keeping the rep when the QR leaves the blade view

A missed QR detection used to hide the anatomy immediately. Blade practice now saves the first lock and follows overlapping detail on the flat practice surface. It validates the estimated motion against textured patches across the image. If the view becomes blank or the match is unreliable, the airway and its lift stay at the last measured pose. Returning to recognizable detail or the original QR resumes the same rep.

The regression replay starts with a small printed QR, moves it completely out of frame, changes scale, blanks the image and returns to the surface at a different position while the QR remains outside the frame. The tracker held the exact pose through the blank interval and recovered the new position within the fixture’s 8 mm tolerance. All 20 software tests passed. The signed standalone update installed and launched on the research iPhone. Physical blade performance depends on the visible surface detail and remains to be checked by hand.

### Recovering a held view while the QR is visible

A hands-on rep stayed on “Holding your view” while the operator moved the blade in front of the print. We reproduced a freeze with a readable QR by spacing analyzed images more than 250 ms apart. Each gap cleared the three-frame filter before it could accept another pose. Initial lock still requires multiple observations. After lock, one validated measurement can resume motion in the original reference frame.

The first recovery patch exposed another failure during the phone check. The phone kept receiving roughly 30 blade frames per second while the view was held. The QR retry deadline could advance on frames where no QR read had even been attempted. Continuous input could postpone recovery indefinitely. The corrected timer advances only after an actual attempt. The replay now covers a slower feed, blank video, movement outside the print, and recovery from the visible QR after discarding the surface images. All 20 software tests passed.

The live screen also keeps the last virtual pose across video interruptions, reports a video pause separately, and keeps the screen awake during hands-free practice. The research build overwrites one status sample in the app cache with the analysis time, frame counts, tracking state and whether a QR decoded. A connected developer can inspect that sample locally. It contains no pixels, audio or motion path.

### November 27, 2026 — lifting past the entry marker

The paired blade preview showed two different holds while the video kept moving. In one, the entry print left the usable image. In another, Vision found all four corners but the tracker rejected the pose. The live diagnostics now show the analyzed blade frame beside the airway, with the detected square outlined.

The new digital station has a fixed entry and distinct codes on rear, upper and side faces. Startup requires three consistent sightings including the entry. After lock the tracker fits all visible station corners in a common coordinate system. An inconsistent overlap or blank view holds the last measured pose. A side face can recover the original mouth after an interruption. The original single print retains its separate surface-tracking mode.

**Play marker replay** renders camera images and sends them through the same Vision detector and tracker as live practice. The sequence advances, lifts, angles up, sweeps both ways, covers the lens for one frame, recovers, releases and withdraws. The first digital layout reached 15.1 mm and 10.2 degrees of error on that trajectory. Adding angled companion markers gave the fit more depth information. On the same 800-by-480 raster replay, the largest translation error was 1.92 mm and the largest rotation error was 1.32 degrees. The entry square was geometrically outside the image throughout both sweeps. These figures measure one synthetic trajectory with nominal optics.

In the private research build, a curved contact profile follows the blade lens. Vertices labeled as tongue deform locally when that profile approaches them, in addition to the existing tip-driven lift. The contact envelope approximates tissue response. At the same camera pose during partial lift, enabling local contact changed about 2.1% of the rendered pixels by more than three RGB levels in at least one channel. A free-angle control produced identical images. All 22 core tests passed. The signed build installed on the paired research iPhone. Physical marker coverage, force feedback and clinical fidelity are unverified. The reserved 24-sweep carton test remains on hold.

The completed iPhone replay reported 101 generated frames. Two acquired the entry, 98 tracked, and the deliberate blank frame held. All 24 frames in the two digital sweeps tracked without the entry QR. The app loaded the research tissue rig. These are replay frames, separate from the reserved physical sweeps.

### November 27, 2026 — marking and recovering a useful view

The guided rep opens with an unlabelled airway. The learner locates the epiglottis, chooses a first view, releases until the opening is reduced to a sliver or disappears, and marks a useful view again. Each mark freezes its own frame. Reference outlines and POGO ranges appear after both sets of answers are submitted.

The research build uses thirteen views from the modeled size-4 lift. The public build uses the synthetic teaching drawings. The on-screen controls exercise the sequence without a fixture. The Mac target input maps optical blade height to the same sequence. Its physical accuracy and the authored POGO references still need independent review. Reaching the stop, repeating a mark, or interrupting tracking cannot complete a rep.

### November 27, 2026 — keeping the first mark through a tracking pause

A missing blade pose or a gap between samples previously cleared the guided rep and recalibrated its starting height. The trainer now holds the last image, preserves the first marked view and resumes from the same Mac target calibration. Marking is disabled during a pause. If loss was still in progress, the learner must first see a useful opening again and then demonstrate a sustained loss with valid tracking. A loss already demonstrated before the interruption remains credited.

Regression tests reproduced the reset and now verify that explicit tracking drops and gaps between samples preserve the first mark. The tests also reject a mark on a paused image and require fresh tracked evidence after reacquisition. The signed change installed as standalone staging build 5.

### November 27, 2026 — hybrid coaching reaches the guided rep

We spent three days on the printed practice mouth and its sensing. The competition judges the Firebase AI Logic hybrid session, and that path had only ever been compiled. No Firebase project existed. We stopped the sensor work and went back to the hybrid session.

A separate Firebase project now backs the trainer, with AI Logic on the Gemini Developer API and App Check enforced. The coach had only been attached to the recorded rep. It is now one shared panel on both review screens. After the learner marks a view, loses it, recovers it and answers the landmark and POGO questions, the panel offers coaching on the iPhone's own model, or a hybrid session that tries the on-device model first and Gemini second. Cloud use still needs a separate yes for each rep.

Research builds verify with an App Check debug token kept in the local, untracked Firebase configuration. The build with the debug token no longer carries the App Attest entitlement.

A new simulator test walks the whole guided rep, allows the cloud fallback and waits for an answer from the live project. It returned cloud coaching in 38 seconds including the rep. The simulator has no on-device model, so this proves the Firebase route and the fallback. The on-device route on a phone is still unverified. All 27 core tests and both existing simulator walkthroughs passed.
