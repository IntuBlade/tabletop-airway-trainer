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

Print the [US Letter trainer QR sheet](Artwork/trainer-qr-print-letter.pdf) at **Actual Size (100%)**. Check that the distance between the two ruler ticks is 40 mm. Lay the sheet flat on the table. Choose **Practice with blade**. Hold the whole code in the blade view. Tracking automatically starts the rep at a preset angle just inside the teeth. In the research scene, forward and backward blade travel follows the bend from mouth to throat. Blade turns and sideways movement steer the view. Keep the QR still and in view. If tracking drops, the app shows the blade video and resumes from the same reference when the QR returns. Tap **Reset to teeth** to start again from the current blade position.

The optional local build input `TRAINER_RESEARCH_SCENE` accepts an authorized, meter-scale USDZ named `PrivateAirway.usdz` in camera-local coordinates. It is used in the live-motion screen. The default renderer uses schematic geometry.

For a private single-mesh airway with vertex colors, [the Blender authoring script](Tools/author_airway.py) creates an editable Blender scene and a textured USDZ for the research build. Run it on macOS with Blender 4.2's Python module, NumPy, and the Apple USD tools:

```sh
python Tools/author_airway.py /path/to/original/PrivateAirway.usdz /path/to/private/output
```

For regional tissue colors and surface finishes, add `--region-manifest /path/to/mesh.json`. The matching binary mesh and landmark labels must sit beside that manifest as `mesh.bin` and `mesh.landmarks.json`.

If that mesh provides a lift field and vallecula landmark, the live renderer also responds to tracked blade elevation near the pocket. Lowering or withdrawing the blade releases the tissue. This is a pose-driven training approximation.

Pass the exported `/path/to/private/output/PrivateAirway.usdz` as `TRAINER_RESEARCH_SCENE` when generating the blade-enabled project. Store the source mesh, generated textures, Blender scene and rendered previews in the private workspace.
