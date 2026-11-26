# Tabletop airway trainer for iOS

A standalone training prototype. The goal is to place a virtual mannequin on a table and use a physical IntuBlade to practice finding, losing, and recovering the simulated view.

Open `TabletopTrainer.xcodeproj`, choose the **TabletopTrainer** scheme, and run it on an iOS 26+ simulator. Select **Try recorded practice**, play the synthetic sequence, and mark the first and recovered frames. Answer the two landmark questions and estimate visible glottic length on each frame. The app reveals the two answers together and saves the two most recent completed reps locally. Use **Explore** to see the fixture labels before an unaided rep.

The blade-enabled build uses the blade video for tabletop placement and practice. The head is a shaped shell with an original generated face texture.

Run `swift test` from this directory for recovery and scoring checks. Run the **TabletopTrainer** scheme's tests on an iPhone simulator for the end-to-end recorded exercise. View [development notes](BUILD-LOG.md) for the verified milestones.


## Firebase research variant

The default scheme runs the full recorded practice with the local answer card. For the separate Firebase build, place the standalone trainer’s research-only `GoogleService-Info.plist` here and run `TRAINER_FIREBASE=1 ruby generate.rb` with the xcodeproj gem installed. Open `TabletopTrainerFirebase.xcodeproj`. The generator pins Firebase Apple SDK 12.19.3, the release line with the documented iOS hybrid session. Register the trainer bundle ID and configure AI Logic and App Check in the research project. Use App Attest on the phone and a privately registered debug token for simulator development.

After reveal, **Coach on this iPhone** requests on-device inference only. **Allow cloud fallback** requires a separate choice for the current rep. The coach accepts one of two predefined lesson objectives and leaves the deterministic answer card visible. It sends only the synthetic outcome and POGO estimate and reference bands. Keep the Firebase config, credentials, and any debug token out of published files.

Coach compilation and real provider verification are tracked independently. Use one synthetic rep to verify airplane-mode local coaching, explicitly approved Firebase fallback, and the deterministic result when the model cannot provide an approved objective.

## Live blade motion on a research iPhone

With access to the licensed device frameworks, set `TRAINER_BLADE_SDK` to their local directory and run `ruby generate.rb`. Build the generated **TabletopTrainerBlade** project for the phone. The SDK requires versioned app metadata. The generated project contains local paths and is excluded from source control.

Print the [US Letter trainer QR sheet](Artwork/trainer-qr-print-letter.pdf) at **Actual Size (100%)**. Check that the distance between the two ruler ticks is 40 mm. Lay the sheet flat on the table. Choose **Place head with blade**. Look down at the full code with the blade. An outline shows the detected square, and the head appears automatically with its mouth above the center. The head fits the first usable view and stays at the displayed scale during movement. Choose **Use life-size head** for one-to-one travel, or **Fit head to current view** to place a smaller model again. Tap **Start practice** and move toward the visible mouth. Crossing the lip opening switches to the interior. Withdrawing past the lips brings the head back. The screen returns to live blade video when it loses the marker. Keep the reference stationary through setup and practice.

The optional local build input `TRAINER_RESEARCH_SCENE` accepts an authorized, meter-scale USDZ named `PrivateAirway.usdz` in camera-local coordinates. It is used in the live-motion screen. The default renderer uses schematic geometry.
