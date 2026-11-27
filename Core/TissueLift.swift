import SceneKit
import simd

/// Pose-driven contact with the authored training airway, in meters.
struct TissueLiftContact {
    let pocket: SIMD3<Float>
    let axis: SIMD3<Float>

    func weight(for camera: simd_float4x4?) -> Float {
        guard let camera else { return 0 }
        // A virtual contact point relative to the tracked lens. This is a
        // simulation offset, not a calibration of the physical IntuBlade tip.
        let point = camera * SIMD4<Float>(0, 0.010, -0.019, 1)
        let offset = SIMD3(point.x, point.y, point.z) - pocket
        let rise = simd_dot(offset, axis)
        let miss = simd_length(offset - rise * axis)
        func ramp(_ x: Float, _ low: Float, _ high: Float) -> Float {
            let t = min(1, max(0, (x - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }
        // A small dead zone rejects pose noise. Contact fades off to either side
        // of the pocket and releases if the blade passes right through it.
        return ramp(rise, 0.001, 0.009) * (1 - ramp(miss, 0.005, 0.014))
            * (1 - ramp(rise, 0.015, 0.026))
    }
}

struct AirwayLiftRig {
    let contact: TissueLiftContact
    private let geometry: SCNGeometry

    init?(root: SCNNode) {
        guard let pocket = root.childNode(withName: "LiftPocket", recursively: true),
              let direction = root.childNode(withName: "LiftDirection", recursively: true),
              let airway = root.childNode(withName: "Airway", recursively: true),
              let source = airway.geometry,
              [3, 6].contains(source.sources(for: .texcoord).count),
              let geometry = source.copy() as? SCNGeometry else { return nil }
        let axis = direction.simdWorldPosition - pocket.simdWorldPosition
        guard simd_length(axis) > 0.0001 else { return nil }
        contact = TissueLiftContact(pocket: pocket.simdWorldPosition, axis: simd_normalize(axis))
        self.geometry = geometry
        // Clone only the binding so simultaneous practice views have independent uniforms.
        airway.geometry = geometry
        let local = simd_normalize(airway.simdConvertVector(contact.axis, from: nil))
        let corrective = source.sources(for: .texcoord).count == 6 ? """
            float2 xy = _geometry.texcoords[3];
            float2 zx = _geometry.texcoords[4];
            float2 nyz = _geometry.texcoords[5];
            float phase = clamp((travel + 0.0045) / 0.0135, 0.0, 1.0);
            float partial = 4.0 * phase * (1.0 - phase);
            _geometry.position.xyz += partial * float3(xy.x, 1.0 - xy.y, zx.x);
            adjustedNormal += partial * float3(1.0 - zx.y, nyz.x, 1.0 - nyz.y);
            """ : ""
        geometry.shaderModifiers = [.geometry: """
            #pragma arguments
            float travel;
            float3 liftAxis;
            #pragma body
            float2 lift = _geometry.texcoords[1];
            _geometry.position.xyz += liftAxis * travel * lift.x;
            // SceneKit reverses the V coordinate on import from USD.
            float2 yz = _geometry.texcoords[2];
            float3 normalDelta = float3(1.0 - lift.y, yz.x, 1.0 - yz.y);
            float3 adjustedNormal = _geometry.normal + normalDelta * (travel / 0.009);
            \(corrective)
            _geometry.normal = normalize(adjustedNormal);
            """]
        geometry.setValue(NSValue(scnVector3: SCNVector3(local)), forKey: "liftAxis")
        update(camera: nil)
    }

    func update(camera: simd_float4x4?) {
        let weight = contact.weight(for: camera)
        geometry.setValue(NSNumber(value: -0.0045 + 0.0135 * weight), forKey: "travel")
    }
}
