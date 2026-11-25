# Development notes

## November 24, 2026

- Defined the exercise around two marked frames and a find–lose–recover movement. The iPhone camera has one job during setup: anchor a virtual head on the table. The blade camera has a separate job during practice: estimate the physical blade position relative to the head's reference.
- Added a SwiftUI recorded exercise with a synthetic fixture. The learner marks two frames, answers both sets of questions, reviews both reference frames, then retries. The first simulator walkthrough passed. Unit checks covered a sustained loss and partial return, flicker, tracking dropout, invalid motion, and item-level landmark results.
- Added an ARKit table-placement prototype using an original geometric stand-in. The recorded exercise and placement prototype can be built together. Live tabletop registration, the final anatomical model, blade pose, and Firebase inference need their own verification.
- Started device verification of the separate signed recording-free research preview. The build installed and launched on the paired physical iPhone using the research staging app. The live folder had 12 entries before installation and after launch, with no new, removed or changed entries. Blade motion and disconnect behavior still need observation.
- The eventual public repo should contain original code, cleared assets, dated notes, and reproducible test results. Hardware SDKs, source recordings, private models, and the private research repository history stay in their current workspaces.
- Added a consent-gated Firebase adapter with a reviewed-text allowlist and a deterministic answer card. The Firebase variant compiled against SDK 12.19.3. App Check and both inference routes still need a configured research project and a device run.
