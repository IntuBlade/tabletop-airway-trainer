import SceneKit
import simd

/// The guide carries a rigid lens-to-tip offset through the authored approach.
/// All positions are meters. Orientations describe the lens in airway space.
struct PairedBladePath {
    let tipInLens: SIMD3<Float>
    let entryLens: simd_float4x4
    let seatedTip: simd_float4x4
    let middleTip: SIMD3<Float>
    let fullLift: Float
    private(set) var advanceMeters: Float = 0

    init?(root: SCNNode) {
        guard let guide = root.childNode(withName: "BladeGuide", recursively: true),
              let tip = guide.childNode(withName: "TipInLens", recursively: false),
              let entry = guide.childNode(withName: "EntryLens", recursively: false),
              let middle = guide.childNode(withName: "MiddleTip", recursively: false),
              let seated = guide.childNode(withName: "SeatedTip", recursively: false),
              let raised = guide.childNode(withName: "RaisedTip", recursively: false) else { return nil }
        tipInLens = tip.simdPosition
        entryLens = entry.simdWorldTransform
        seatedTip = seated.simdWorldTransform
        middleTip = middle.simdWorldPosition
        fullLift = simd_distance(raised.simdWorldPosition, seated.simdWorldPosition)
        guard BladeRegistration.isRigid(entryLens), BladeRegistration.isRigid(seatedTip),
              simd_length(tipInLens) > 0, fullLift.isFinite, fullLift > 0.001 else { return nil }
        // Cumulative lens travel maps a measured straight advance onto the curve.
        var previous = entry.simdWorldPosition
        for step in 1...64 {
            let lens = centeredLens(at: Float(step) / 64).columns.3.xyz
            advanceMeters += simd_distance(previous, lens)
            arcLengths.append(advanceMeters)
            previous = lens
        }
        guard advanceMeters.isFinite, advanceMeters > 0 else { return nil }
    }

    private var arcLengths: [Float] = [0]

    private func centeredLens(at t: Float) -> simd_float4x4 {
        let start = (entryLens * SIMD4(tipInLens, 1)).xyz
        let end = seatedTip.columns.3.xyz
        let bow = middleTip - (start + end) / 2
        let tip = start + t * (end - start) + sin(.pi * t) * bow
        let orientation = simd_slerp(simd_quatf(entryLens), simd_quatf(seatedTip), t)
        var lens = simd_float4x4(orientation)
        lens.columns.3 = SIMD4(tip - orientation.act(tipInLens), 1)
        return lens
    }

    func camera(for movement: simd_float4x4) -> simd_float4x4 {
        let depth = min(max(-movement.columns.3.z, 0), advanceMeters)
        let upper = arcLengths.dropFirst().firstIndex { $0 >= depth } ?? arcLengths.count - 1
        let lower = upper - 1
        let span = arcLengths[upper] - arcLengths[lower]
        let fraction = span > 0 ? (depth - arcLengths[lower]) / span : 0
        let t = (Float(lower) + fraction) / Float(arcLengths.count - 1)
        var steering = movement
        steering.columns.3.z += depth
        return centeredLens(at: t) * steering
    }
}

/// Pose-driven contact with the authored training airway, in meters.
struct TissueLiftContact {
    let pocket: SIMD3<Float>
    let axis: SIMD3<Float>
    var tipInLens = SIMD3<Float>(0, 0.010, -0.019)
    var fullLift: Float = 0.009

    func weight(for camera: simd_float4x4?) -> Float {
        guard let camera else { return 0 }
        let point = camera * SIMD4(tipInLens, 1)
        let offset = SIMD3(point.x, point.y, point.z) - pocket
        let rise = simd_dot(offset, axis)
        let miss = simd_length(offset - rise * axis)
        func ramp(_ x: Float, _ low: Float, _ high: Float) -> Float {
            let t = min(1, max(0, (x - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        // A small dead zone rejects pose noise. Contact fades off to either side
        // of the pocket and releases if the blade passes right through it.
        return ramp(rise, 0.001, fullLift) * (1 - ramp(miss, 0.005, 0.014))
            * (1 - ramp(rise, fullLift + 0.006, fullLift + 0.017))
    }
}

struct AirwayLiftRig {
    let contact: TissueLiftContact
    private let geometry: SCNGeometry
    private let airwayFromWorld: simd_float4x4
    private let dorsalInLens: [SIMD3<Float>]

    init?(root: SCNNode, guide: PairedBladePath? = nil) {
        guard let pocket = root.childNode(withName: "LiftPocket", recursively: true),
              let direction = root.childNode(withName: "LiftDirection", recursively: true),
              let airway = root.childNode(withName: "Airway", recursively: true),
              let source = airway.geometry,
              [3, 6, 7].contains(source.sources(for: .texcoord).count),
              let geometry = source.copy() as? SCNGeometry else { return nil }
        let axis = direction.simdWorldPosition - pocket.simdWorldPosition
        guard simd_length(axis) > 0.0001 else { return nil }
        if let guide = guide ?? PairedBladePath(root: root) {
            contact = TissueLiftContact(pocket: guide.seatedTip.columns.3.xyz,
                                        axis: simd_normalize(axis), tipInLens: guide.tipInLens,
                                        fullLift: guide.fullLift)
        } else {
            contact = TissueLiftContact(pocket: pocket.simdWorldPosition, axis: simd_normalize(axis))
        }
        let channels = source.sources(for: .texcoord).count
        let guideNode = root.childNode(withName: "BladeGuide", recursively: true)
        dorsalInLens = channels == 7 ? (0..<4).compactMap {
            guideNode?.childNode(withName: "Dorsal\($0)", recursively: false)?.simdPosition
        } : []
        guard channels != 7 || dorsalInLens.count == 4 else { return nil }
        airwayFromWorld = airway.simdWorldTransform.inverse
        self.geometry = geometry
        // Clone only the binding so simultaneous practice views have independent uniforms.
        airway.geometry = geometry
        let local = simd_normalize(airway.simdConvertVector(contact.axis, from: nil))
        let corrective = channels >= 6 ? """
            float2 xy = _geometry.texcoords[3];
            float2 zx = _geometry.texcoords[4];
            float2 nyz = _geometry.texcoords[5];
            float phase = clamp((travel + 0.0045) / 0.0135, 0.0, 1.0);
            float partial = 4.0 * phase * (1.0 - phase);
            _geometry.position.xyz += partial * float3(xy.x, 1.0 - xy.y, zx.x);
            adjustedNormal += partial * float3(1.0 - zx.y, nyz.x, 1.0 - nyz.y);
            """ : ""
        let dorsalArguments = dorsalInLens.indices.map { "float3 dorsal\($0);" }.joined(separator: "\n")
        // The CAD section travels rigidly with the lens. Only tongue-labeled
        // tissue within the rounded contact envelope can receive this displacement.
        let shaftContact = dorsalInLens.count == 4 ? """
            float3 tonguePoint = _geometry.position.xyz;
            float3 profile[4] = { dorsal0, dorsal1, dorsal2, dorsal3 };
            float compression = 0.0;
            for (int i = 0; i < 3; i++) {
                float3 ab = profile[i+1] - profile[i];
                float t = clamp(dot(tonguePoint - profile[i], ab) / max(dot(ab,ab), 1e-10), 0.0, 1.0);
                float3 offset = tonguePoint - (profile[i] + t * ab);
                float distanceToBlade = length(offset);
                compression = max(compression, 0.004 * (1.0 - smoothstep(0.001, 0.006, distanceToBlade)));
            }
            _geometry.position.xyz += liftAxis * compression * _geometry.texcoords[6].x;
            """ : ""
        geometry.shaderModifiers = [.geometry: """
            #pragma arguments
            float travel;
            float3 liftAxis;
            \(dorsalArguments)
            #pragma body
            float2 lift = _geometry.texcoords[1];
            _geometry.position.xyz += liftAxis * travel * lift.x;
            // SceneKit reverses the V coordinate on import from USD.
            float2 yz = _geometry.texcoords[2];
            float3 normalDelta = float3(1.0 - lift.y, yz.x, 1.0 - yz.y);
            float3 adjustedNormal = _geometry.normal + normalDelta * (travel / 0.009);
            \(corrective)
            \(shaftContact)
            _geometry.normal = normalize(adjustedNormal);
            """]
        geometry.setValue(NSValue(scnVector3: SCNVector3(local)), forKey: "liftAxis")
        update(camera: nil)
    }

    func update(camera: simd_float4x4?, measuredWeight: Float? = nil) {
        for (i, point) in dorsalInLens.enumerated() {
            let local = camera.map { (airwayFromWorld * $0 * SIMD4(point, 1)).xyz } ?? SIMD3<Float>(repeating: 10)
            geometry.setValue(NSValue(scnVector3: SCNVector3(local)), forKey: "dorsal\(i)")
        }
        let weight = measuredWeight ?? contact.weight(for: camera)
        geometry.setValue(NSNumber(value: -0.0045 + 0.0135 * weight), forKey: "travel")
    }
}
