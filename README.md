# Tabletop airway trainer for iOS

A standalone training prototype. The goal is to place a virtual mannequin on a table and use a physical IntuBlade to practice finding, losing, and recovering the simulated view.

Open `TabletopTrainer.xcodeproj`, choose the **TabletopTrainer** scheme, and run it on an iOS 26+ simulator. Select **Try recorded practice**, play the synthetic sequence, and mark the first and recovered frames. Answer the two landmark questions and estimate visible glottic length on each frame. The app reveals the two answers together and saves the two most recent completed reps locally. Use **Explore** to see the fixture labels before an unaided rep.

**Place head on table** uses an iPhone camera and ARKit. The 3D model has an original generated face texture on a shaped shell. After placement, select **Preview blade movement** to watch a virtual camera travel through a schematic airway. The camera follows a programmed position and rotation. Working clearance, target geometry, blade tracking and the anatomical reference require separate evidence. The home-screen photograph was generated for this project and depicts a generic training scene.

Run `swift test` from this directory for recovery and scoring checks. Run the **TabletopTrainer** scheme's tests on an iPhone simulator for the end-to-end recorded exercise. View [development notes](BUILD-LOG.md) for the verified milestones.


## Firebase research variant

The default scheme runs the full recorded practice with the local answer card. For the separate Firebase build, place the standalone trainer’s research-only `GoogleService-Info.plist` here and run `TRAINER_FIREBASE=1 ruby generate.rb` with the xcodeproj gem installed. Open `TabletopTrainerFirebase.xcodeproj`. The generator pins Firebase Apple SDK 12.19.3, the release line with the documented iOS hybrid session. Register the trainer bundle ID and configure AI Logic and App Check in the research project. Use App Attest on the phone and a privately registered debug token for simulator development.

After reveal, **Coach on this iPhone** requests on-device inference only. **Allow cloud fallback** requires a separate choice for the current rep. The coach accepts one of two predefined lesson objectives and leaves the deterministic answer card visible. It sends only the synthetic outcome and POGO estimate and reference bands. Keep the Firebase config, credentials, and any debug token out of published files.

Coach compilation and real provider verification are tracked independently. Use one synthetic rep to verify airplane-mode local coaching, explicitly approved Firebase fallback, and the deterministic result when the model cannot provide an approved objective.

## Live blade motion on a research iPhone

With access to the licensed device frameworks, set `TRAINER_BLADE_SDK` to their local directory and run `ruby generate.rb`. Build the generated **TabletopTrainerBlade** project for the phone. The SDK requires versioned app metadata. The generated project contains local paths and is excluded from source control.

Open [the trainer QR](Artwork/motion-marker.png) on a second screen. Connect the blade and choose **Live blade motion**. Aim at the QR until **Marker found** appears, then tap **Set starting view**. Turn or move the blade with the QR visible. Covering it or disconnecting the blade should clear the view. This screen processes frames in memory. A nominal 40 mm code and assumed optics support relative motion only. Screen zoom affects scale. Setting a starting view does not register the virtual mouth to the tabletop.

The optional local build input `TRAINER_RESEARCH_SCENE` accepts an authorized, meter-scale USDZ named `PrivateAirway.usdz` in camera-local coordinates. It is used in the live-motion screen. The default renderer uses schematic geometry.

## Place the head relative to a reference

Open **Place head on table**. Display the trainer QR at a measured black-square width of 40 mm on a stationary surface next to the practice area. Keep it visible to the phone camera while tapping the detected tabletop. **Mouth registered** means the app has stored the head and QR in a shared coordinate system. Moving the reference requires a new placement. **Use blade at placed mouth** uses that saved registration; this path requires SDK approval for the standalone app identity. Lip alignment is a model estimate, and the blade optics still need measurement.
