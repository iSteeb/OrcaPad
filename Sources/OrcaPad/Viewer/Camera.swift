// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

import simd
import UIKit

// MARK: - Small matrix library (column-major, MSL-compatible)

enum Math {
    static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(columns: (
            simd_float4(x, 0, 0, 0),
            simd_float4(0, y, 0, 0),
            simd_float4(0, 0, z, -1),
            simd_float4(0, 0, z * near, 0)
        ))
    }

    static func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let r = simd_normalize(simd_cross(f, up))
        let u = simd_cross(r, f)
        return simd_float4x4(columns: (
            simd_float4(r.x, u.x, -f.x, 0),
            simd_float4(r.y, u.y, -f.y, 0),
            simd_float4(r.z, u.z, -f.z, 0),
            simd_float4(-simd_dot(r, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        ))
    }

    static func identity() -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
    }

    /// Rotation about +Y (viewer up). Maps engine z-rotation onto viewer
    /// space: T·Rz(θ)·T⁻¹ = Ry(θ) for the (x,y,z)e→(x,z,-y)v mapping.
    static func rotateY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        ))
    }

    static func translate(_ t: simd_float3) -> simd_float4x4 {
        simd_float4x4(columns: (
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 1, 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(t.x, t.y, t.z, 1)
        ))
    }

    static func scale(_ s: Float) -> simd_float4x4 {
        simd_float4x4(diagonal: simd_float4(s, s, s, 1))
    }
}

/// Desktop camera view presets (MainFrame select_view).
enum CameraViewPreset: String, CaseIterable, Identifiable, Sendable {
    case defaultValue = "Default View"
    case top = "Top"
    case bottom = "Bottom"
    case front = "Front"
    case rear = "Rear"
    case left = "Left"
    case right = "Right"

    var id: String { rawValue }

    /// Yaw/pitch in the viewer frame (engine +X is viewer +X, engine +Y is
    /// viewer -Z): eye azimuth and elevation above the horizon.
    var angles: (yaw: Float, pitch: Float) {
        switch self {
        case .defaultValue: return (-0.65, 0.42)
        case .top: return (0, OrbitCamera.maxPitch)
        case .bottom: return (0, OrbitCamera.minPitch)
        // engine -Y (the printer front) is viewer +Z -> yaw +pi/2
        case .front: return (Float.pi / 2, 0)
        case .rear: return (-Float.pi / 2, 0)
        case .right: return (0, 0)
        case .left: return (Float.pi, 0)
        }
    }
}

// MARK: - Orbit ("turntable") camera

/// Spherical camera around a target point — the classic slicer view.
/// One-finger drag orbits, pinch zooms, two-finger drag pans.
final class OrbitCamera {
    /// Bed centre, slightly raised so the default view frames the object.
    var target = simd_float3(0, 15, 0)
    var yaw: Float = -0.65     // radians; 0 looks down -Z... (eye azimuth)
    var pitch: Float = 0.42    // radians above horizon
    var distance: Float = 330

    let fovY = Float.pi / 4
    let near: Float = 1
    let far: Float = 5000

    var eye: simd_float3 {
        let cp = cos(pitch)
        return target + distance * simd_float3(cp * cos(yaw), sin(pitch), cp * sin(yaw))
    }

    var forward: simd_float3 { simd_normalize(target - eye) }
    var right: simd_float3 { simd_normalize(simd_cross(forward, simd_float3(0, 1, 0))) }
    var upAxis: simd_float3 { simd_cross(right, forward) }

    var viewMatrix: simd_float4x4 {
        Math.lookAt(eye: eye, center: target, up: simd_float3(0, 1, 0))
    }

    func projection(aspect: Float) -> simd_float4x4 {
        Math.perspective(fovY: fovY, aspect: aspect, near: near, far: far)
    }

    func orbit(dx: Float, dy: Float) {
        yaw += dx * 0.008
        pitch = min(max(pitch + dy * 0.006, Self.minPitch), Self.maxPitch)
    }

    static let maxPitch = Float.pi / 2 - 0.04
    static let minPitch = -(Float.pi / 2 - 0.04)

    /// Applies a desktop camera view preset (keeps target and distance).
    func apply(_ preset: CameraViewPreset) {
        let angles = preset.angles
        yaw = angles.yaw
        pitch = angles.pitch
    }

    func zoom(by scale: Float) {
        distance = min(max(distance / max(scale, 0.05), 70), 1400)
    }

    /// Two-finger drag: translate the target in the camera's screen plane.
    func pan(dx: Float, dy: Float) {
        let k = distance * 0.0016
        let delta = -right * (dx * k) + upAxis * (dy * k)
        target += delta
        target.y = min(max(target.y, 0), 400)
        target.x = min(max(target.x, -300), 300)
        target.z = min(max(target.z, -300), 300)
    }
}
