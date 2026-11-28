# Tabletop airway trainer for iOS

A standalone training prototype. The goal is to place a virtual mannequin on a table and use a physical IntuBlade to practice finding, losing, and recovering the simulated view.

Open `TabletopTrainer.xcodeproj`, choose the **TabletopTrainer** scheme, and run it on an iOS 26+ simulator. Select **Try recorded practice**, play the synthetic sequence, and mark the first and recovered frames. Answer the two landmark questions and estimate visible glottic length on each frame. The app reveals the two answers together and saves the two most recent completed reps locally. Use **Explore** to see the fixture labels before an unaided rep.

The blade-enabled build uses the blade video for tabletop placement and practice. The head is a shaped shell with an original generated face texture.

Run `swift test` from this directory for recovery and scoring checks. Run the **TabletopTrainer** scheme's tests on an iPhone simulator for the end-to-end recorded exercise. View [development notes](BUILD-LOG.md) for the verified milestones.


## Firebase research variant

The default scheme runs the full recorded practice with the local answer card. For the separate Firebase build, place the standalone trainer’s research-only `GoogleService-Info.plist` here and run `TRAINER_FIREBASE=1 ruby generate.rb` with the xcodeproj gem installed. Open `TabletopTrainerFirebase.xcodeproj`. The generator pins Firebase Apple SDK 12.19.3, the release line with the documented iOS hybrid session. Register the trainer bundle ID in your own Firebase project, enable AI Logic with the Gemini Developer API, and let it enforce App Check.

App Check accepts a debug token for development. Register a token under App Check, Apps, Manage debug tokens. Add it to your local `GoogleService-Info.plist` as the string `APP_CHECK_DEBUG_TOKEN`, and the app passes it to the debug provider on a phone or in the simulator. A simulator build with no token prints a generated one in the Xcode log for you to register. Set `TRAINER_APP_ATTEST=1` to build with the App Attest entitlement for a phone build that carries no debug token. Set `TRAINER_FIREBASE_CONFIG` to use a configuration file stored elsewhere.

The coach appears on the review screen of the guided rep and the recorded rep. **Coach on this iPhone** requests on-device inference only. **Allow cloud fallback** requires a separate choice for the current rep and opens a hybrid session, with Apple’s on-device model first and Gemini second. The coach accepts one of two predefined lesson objectives and leaves the deterministic answer card visible. It sends only the synthetic outcome and POGO estimate and reference bands. Keep the Firebase config, credentials, and any debug token out of published files.

`testGuidedRepReviewGetsHybridCoaching` walks a guided rep in the simulator, allows the cloud fallback and waits for a coached answer. It skips when no Firebase project is configured. Use one synthetic rep on a phone to verify airplane-mode local coaching and the deterministic result when the model cannot provide an approved objective.

## Live blade motion on a research iPhone

With access to the licensed device frameworks, set `TRAINER_BLADE_SDK` to their local directory and run `ruby generate.rb`. Build the generated **TabletopTrainerBlade** project for the phone. The SDK requires versioned app metadata. The generated project contains local paths and is excluded from source control.

Print the [US Letter trainer QR sheet](Artwork/trainer-qr-print-letter.pdf) at **Actual Size (100%)**. Check that the distance between the two ruler ticks is 40 mm. If your print was resized, open **QR size** in blade practice and enter the measured width of the black square in millimeters, excluding the white border. Saving a different width starts a new reference at the teeth. The optional placed-head station uses the standard 40 mm sheet. Lay the sheet flat on the table. Choose **Practice with blade**. Hold the whole code in the blade view. Tracking automatically starts the rep at a preset angle just inside the teeth. In the research scene, forward and backward blade travel follows the bend from mouth to throat. Blade turns and sideways movement steer the view. Leave the print flat and still. After the first lock, the blade camera tracks overlapping detail on the tabletop, including when the QR leaves the frame. If the blade sees too little detail, the airway holds its last view. Aim back toward the same surface or the print to resume. A video interruption pauses the rep in place. After reconnecting, show the same stationary QR to resume. Leaving blade practice or changing the print width clears the session. Tap **Reset to teeth** to start again from the current blade position.

The optional local build input `TRAINER_RESEARCH_SCENE` accepts an authorized, meter-scale USDZ named `PrivateAirway.usdz` in camera-local coordinates. It is used in the live-motion screen. The default renderer uses schematic geometry.

For a private single-mesh airway with vertex colors, [the Blender authoring script](Tools/author_airway.py) creates an editable Blender scene and a textured USDZ for the research build. Run it on macOS with Blender 4.2's Python module, NumPy, and the Apple USD tools:

```sh
python Tools/author_airway.py /path/to/original/PrivateAirway.usdz /path/to/private/output
```

For regional tissue colors and surface finishes, add `--region-manifest /path/to/mesh.json`. The matching binary mesh and landmark labels must sit beside that manifest as `mesh.bin` and `mesh.landmarks.json`.

For the studio pass, install the Blender authoring add-ons [Ucupaint](https://github.com/ucupumar/ucupaint/tree/64f829b), [ActionPoser](https://github.com/Arminando/ActionPoser/tree/b26a7e8) and [Tissue](https://github.com/alessandro-zomparelli/tissue/tree/d7f4c32) on the authoring machine. Add `--studio` to the regional authoring command. The studio mesh needs tongue, epiglottis and cord labels and a lift field. In the saved Blender scene, move the **Lift** pose bone along local X from 0 to 10 mm to preview rest, partial lift and full exposure. The exporter bakes the materials and samples the pose for the phone.

If that mesh provides a lift field and vallecula landmark, the live renderer also responds to tracked blade elevation near the pocket. Lowering or withdrawing the blade releases the tissue. This is a pose-driven training approximation.

A measured blade profile can register the camera path and contact tip together on a particular studio export. Run the registration step before generating the local research project.

```sh
python Tools/register_blade.py private/studio/PrivateAirway.usdz private/blade-guide.json private/registered/PrivateAirway.usdz
```

The profile names the source package by `airway_sha256`. Supply `tip_in_lens_m` in lens coordinates, with forward along −Z. In airway space supply `entry_lens_m`, `middle_tip_m`, `seated_tip_m` on the resting pocket and `raised_tip_m` along its lift axis. Supply unit lens quaternions `entry_wxyz` and `seated_wxyz` in scalar-first order. The trainer derives lens travel from the resulting curve. It carries one rigid lens-to-tip offset through advance, rotation, lift and withdrawal. Older research assets continue to use their existing path.

Pass the exported `/path/to/private/output/PrivateAirway.usdz` as `TRAINER_RESEARCH_SCENE` when generating the blade-enabled project. Store the source mesh, generated textures, Blender scene and rendered previews in the private workspace.
