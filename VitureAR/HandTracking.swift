//
//  VitureHandTracking.swift
//
//  深度補正:
//    ・wristDepthCompression : 遠い手の視差を圧縮（デフォルト 0.65）
//    ・fingerDepthBias        : 指先が手のひらより深くなりすぎるのを防ぐ（デフォルト 0.55）
//
//  ★ 変更点 (スケール調整):
//    ・wristTargetLength を @Published 変数に昇格
//      → ARView の設定パネルからリアルタイムに手の大きさ・奥行きを調整可能に
//    ・updateHandTracking() 内のハードコード 0.08 を wristTargetLength で置き換え
//

import SwiftUI
import Combine
internal import AVFoundation
import Vision
import RealityKit
import AppKit

// MARK: - Type Aliases
typealias ARSystemColor = NSColor
typealias HandJoint = VNHumanHandPoseObservation.JointName

// MARK: - Hand Data Model
struct HandData: Identifiable {
    let id = UUID()
    var isRight: Bool
    let joints: [HandJoint: CGPoint]
    let indexTip: CGPoint?
    let distance: CGFloat
}

// MARK: - Camera & Vision Manager
final class CameraManager: NSObject, ObservableObject,
                            AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var session = AVCaptureSession()
    @Published var hands: [HandData] = []

    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue  = DispatchQueue(label: "videoQueue", qos: .userInteractive)

    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let req = VNDetectHumanHandPoseRequest()
        req.maximumHandCount = 2
        return req
    }()

    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:       setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { DispatchQueue.main.async { self?.setupCamera() } }
            }
        default:
            print("Camera Access Denied")
        }
    }

    private func getVITURECamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        let disco = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        let devices = disco.devices

        #if os(macOS)
        if let ext = devices.first(where: {
            if #available(macOS 14.0, *) { return $0.deviceType == .external }
            else { return $0.deviceType == .externalUnknown
                       || $0.localizedName.localizedCaseInsensitiveContains("USB") }
        }) { return ext }
        #else
        if #available(iOS 17.0, *),
           let ext = devices.first(where: { $0.deviceType == .external }) { return ext }
        #endif

        return devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
    }

    private func setupCamera() {
        session.beginConfiguration()
        guard let device = getVITURECamera() else { session.commitConfiguration(); return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }

            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            if let conn = videoOutput.connection(with: .video),
               conn.isVideoMirroringSupported {
                conn.isVideoMirrored = true
            }
        } catch { print("Camera Error: \(error)") }
        session.commitConfiguration()
        DispatchQueue.global(qos: .background).async { self.session.startRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
            if let obs = handPoseRequest.results { processHandPose(observations: obs) }
        } catch { print("Vision Error: \(error)") }
    }

    private func processHandPose(observations: [VNHumanHandPoseObservation]) {
        guard !observations.isEmpty else {
            DispatchQueue.main.async { self.hands.removeAll() }
            return
        }

        struct TempHand {
            var isRight: Bool
            let joints: [HandJoint: CGPoint]
            let indexTip: CGPoint?
            let distance: CGFloat
            let centerX: CGFloat
        }

        var tempHands: [TempHand] = []
        for obs in observations {
            var points: [HandJoint: CGPoint] = [:]
            var isRight = false

            if #available(macOS 11.0, iOS 14.0, *) { isRight = obs.chirality == .left }

            do {
                let recognized = try obs.recognizedPoints(.all)
                for (key, pt) in recognized where pt.confidence > 0.3 {
                    points[key] = CGPoint(x: 1.0 - pt.location.x,
                                         y: 1.0 - pt.location.y)
                }
                let tip  = points[HandJoint.indexTip]
                let dist = Self.depthDistance(joints: points)
                let cx   = points[HandJoint.wrist]?.x ?? 0.5
                tempHands.append(
                    TempHand(isRight: isRight, joints: points,
                             indexTip: tip, distance: dist, centerX: cx))
            } catch {}
        }

        if tempHands.count == 2 {
            if tempHands[0].centerX > tempHands[1].centerX {
                tempHands[0].isRight = true;  tempHands[1].isRight = false
            } else {
                tempHands[0].isRight = false; tempHands[1].isRight = true
            }
        }

        let detected = tempHands.map {
            HandData(isRight: $0.isRight, joints: $0.joints,
                     indexTip: $0.indexTip, distance: $0.distance)
        }
        DispatchQueue.main.async { self.hands = detected }
    }

    private static func depthDistance(joints: [HandJoint: CGPoint]) -> CGFloat {
        guard let w = joints[.wrist], let m = joints[.middleMCP] else { return 1.0 }
        let dx = w.x - m.x; let dy = w.y - m.y
        return 1.0 / max(sqrt(dx*dx + dy*dy), 0.01)
    }
}

// MARK: - Calibration Parameters
struct CalibrationParams: Codable {
    var videoScale: CGFloat    = 1.90
    var videoOffsetX: CGFloat  = 0
    var videoOffsetY: CGFloat  = -368
    var offsetX: CGFloat       = -500 // ← ここも必要なら変える
    var offsetY: CGFloat       = -380 // ← ここも必要なら変える
    var scaleX: CGFloat        = 1.5  // ★ 1.0 から 1.5 に変更
    var scaleY: CGFloat        = 1.5  // ★ 1.0 から 1.5 に変更
    var leftParallax: CGFloat  = -11.0
    var rightParallax: CGFloat = 10.0
}

private enum CalibrationKeys {
    static let left  = "calibration.leftParams"
    static let right = "calibration.rightParams"
}


final class CalibrationViewModel: ObservableObject {
    @Published var leftParams  = CalibrationParams(videoOffsetX: 207)  { didSet { save() } }
    @Published var rightParams = CalibrationParams(videoOffsetX: -176) { didSet { save() } }

    init() { load() }

    private func save() {
        let enc = JSONEncoder()
        if let d = try? enc.encode(leftParams)  { UserDefaults.standard.set(d, forKey: CalibrationKeys.left) }
        if let d = try? enc.encode(rightParams) { UserDefaults.standard.set(d, forKey: CalibrationKeys.right) }
    }

    private func load() {
 /*
        let dec = JSONDecoder()
        if let d = UserDefaults.standard.data(forKey: CalibrationKeys.left),
           let v = try? dec.decode(CalibrationParams.self, from: d) { leftParams = v }
        if let d = UserDefaults.standard.data(forKey: CalibrationKeys.right),
           let v = try? dec.decode(CalibrationParams.self, from: d) { rightParams = v }
 */
    }

    func resetHandTransforms() {
        leftParams.offsetX  = 0; leftParams.offsetY   = 0
        leftParams.scaleX   = 1; leftParams.scaleY    = 1
        leftParams.leftParallax = 0
        rightParams.offsetX = 0; rightParams.offsetY  = 0
        rightParams.scaleX  = 1; rightParams.scaleY   = 1
        rightParams.rightParallax = 0
        save()
    }
}

// MARK: - Hand Tracking Coordinator (3D / RealityKit)
final class HandTrackingCoordinator: ObservableObject {
    weak var leftView:  ARView?
    weak var rightView: ARView?
    weak var spacialCoordinator: SpacialCoordinator?
    var cameraManager: CameraManager?

    // ── 映像パラメータ ──
    @Published var videoScale:   Float = 1.90
    @Published var videoOffsetX: Float = 0.0
    @Published var videoOffsetY: Float = -368.0

    // ── 手の変換 ──
    @Published var handScaleX:  Float = 1.5
    @Published var handScaleY:  Float = 1.5
    @Published var handOffsetX: Float = -500
    @Published var handOffsetY: Float = -380
    @Published var handBaseZ:   Float = 0.0

    // ── 描画サイズ ──
    @Published var jointRadius: Float = 0.006
    @Published var boneRadius:  Float = 0.003

    // ── 深度補正パラメータ ──
    /// 遠い手の奥行きを圧縮する係数（0=全圧縮 / 1=圧縮なし）
    /// 値を下げると手を伸ばしたときの沈み込みが減る
    @Published var wristDepthCompression: Float = 0.65

    /// 指のZが手のひらより深くなりすぎるのを防ぐ係数（0=完全に手首と同じZ / 1=IK解をそのまま使用）
    /// 手を伸ばしたとき指先が沈みすぎる場合は下げる
    @Published var fingerDepthBias: Float = 0.55

    // ★ 追加: 手首〜中指MCP間の目標実寸（メートル）
    // 値を上げると → 手が大きく描画され、奥に配置される
    // 値を下げると → 手が小さく描画され、手前に配置される
    // 人間の平均は約 0.08 m（8 cm）。体格や距離感に合わせて調整してください。
    @Published var wristTargetLength: Float = 0.08

    private let fingers: [[HandJoint]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    /// 人間の平均的な骨の長さ（メートル）
    private let boneLengths: [HandJoint: Float] = [
        .thumbCMC: 0.04,  .thumbMP: 0.03,   .thumbIP: 0.03,  .thumbTip: 0.02,
        .indexMCP: 0.07,  .indexPIP: 0.04,  .indexDIP: 0.025,.indexTip: 0.02,
        .middleMCP: 0.075,.middlePIP: 0.045,.middleDIP: 0.025,.middleTip: 0.02,
        .ringMCP: 0.07,   .ringPIP: 0.04,   .ringDIP: 0.025, .ringTip: 0.02,
        .littleMCP: 0.06, .littlePIP: 0.03, .littleDIP: 0.015,.littleTip: 0.015
    ]

    struct TargetPair { let left: ModelEntity; let right: ModelEntity }
    var targets: [TargetPair] = []

    final class HandState {
        var joints: [HandJoint: HandEntityPair] = [:]
        var bones:  [HandEntityPair] = []
        var laser:   HandEntityPair?
    }
    var leftHandState  = HandState()
    var rightHandState = HandState()

    struct HandEntityPair {
        let leftSceneNode:  ModelEntity
        let rightSceneNode: ModelEntity
        func setEnabled(_ v: Bool) {
            leftSceneNode.isEnabled  = v
            rightSceneNode.isEnabled = v
        }
    }

    private var isSetupDone = false
    private var updateSub: Cancellable?

    func setupIfNeeded(leftView: ARView, rightView: ARView, spacial: SpacialCoordinator) {
        guard !isSetupDone else { return }
        self.leftView  = leftView
        self.rightView = rightView
        self.spacialCoordinator = spacial
        let la = AnchorEntity(world: .zero)
        let ra = AnchorEntity(world: .zero)
        leftView.scene.addAnchor(la);  rightView.scene.addAnchor(ra)
        setupTargets(leftAnchor: la, rightAnchor: ra)
        updateSub = leftView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.updateHandTracking()
        }
        isSetupDone = true
    }

    private func setupTargets(leftAnchor: AnchorEntity, rightAnchor: AnchorEntity) {
        typealias ShapeSpec = (pos: simd_float3, mesh: MeshResource, color: ARSystemColor)
        let specs: [ShapeSpec] = [
            (simd_float3(-0.6, 0.0, -2.0), MeshResource.generateBox(size: 0.3),              .systemRed),
            (simd_float3( 0.0, 0.0, -2.0), MeshResource.generateSphere(radius: 0.2),         .systemBlue),
            (simd_float3( 0.6, 0.0, -2.0), MeshResource.generateCylinder(height: 0.4, radius: 0.15), .systemGreen)
        ]
        for spec in specs {
            let mat   = SimpleMaterial(color: spec.color, isMetallic: false)
            let left  = ModelEntity(mesh: spec.mesh, materials: [mat])
            left.position = spec.pos
            left.generateCollisionShapes(recursive: false)
            leftAnchor.addChild(left)
            let right = ModelEntity(mesh: spec.mesh, materials: [mat])
            right.position = spec.pos
            rightAnchor.addChild(right)
            targets.append(TargetPair(left: left, right: right))
        }
    }

    // MARK: - Main update loop
    private func updateHandTracking() {
        guard let hands    = cameraManager?.hands,
              let leftView = leftView,
              let leftHead  = spacialCoordinator?.leftHead,
              let rightHead = spacialCoordinator?.rightHead
        else { return }

        hideAllHandNodes()
        var hitTargetIndices: Set<Int> = []

        let fovDeg: Float    = Float(spacialCoordinator?.fieldOfView ?? 46.0)
        let baseWidth: Float = 1920.0
        let baseHeight: Float = 1080.0
        let pxToMeters: Float = 1.0 / 1000.0
        let fovRad   = fovDeg * .pi / 180.0
        let screenZ  = -(baseWidth * pxToMeters / 2.0) / tan(fovRad / 2.0)

        // スクリーン基準距離（screenZ は負）
        let refDist = -screenZ  // 正値

        for hand in hands {
            let currentState = hand.isRight ? rightHandState : leftHandState
            let color: ARSystemColor = hand.isRight ? .orange : .cyan

            // ── STEP 1: 各関節のスクリーン座標を3Dレイ（正規化）に変換 ──
            var jointRays: [HandJoint: simd_float3] = [:]
            for (jointName, point) in hand.joints {
                let px = Float(point.x) * baseWidth
                let py = Float(point.y) * baseHeight
                let apx = (px * handScaleX) + handOffsetX
                let apy = (py * handScaleY) + handOffsetY
                var cx = apx - (baseWidth  / 2.0)
                var cy = apy - (baseHeight / 2.0)
                cx = (cx * videoScale) + videoOffsetX
                cy = (cy * videoScale) + videoOffsetY
                let lx = cx * pxToMeters
                let ly = -cy * pxToMeters
                jointRays[jointName] = normalize(simd_float3(lx, ly, screenZ))
            }

            // ── STEP 2: 手首の3D位置を推定し、深度を圧縮する ──
            var wrist3D: simd_float3 = simd_float3(0, 0, screenZ)
            if let rayWrist = jointRays[.wrist], let rayMid = jointRays[.middleMCP] {
                // ★ 変更: ハードコード 0.08 → wristTargetLength を使用
                // 手首〜中指MCP間の実寸からZを逆算
                let targetLength: Float = wristTargetLength * handScaleX
                let distRays = distance(rayWrist, rayMid)
                let rawT = targetLength / max(distRays, 0.001)

                // 🔑 深度圧縮: 遠い手ほど視差が激しくなる問題を抑制
                let excess       = rawT - refDist
                let compExcess   = excess > 0
                    ? excess * wristDepthCompression
                    : excess
                let compressedT  = refDist + compExcess

                wrist3D  = rayWrist * compressedT
                wrist3D.z += handBaseZ
                wrist3D  = rayWrist * (wrist3D.z / rayWrist.z)
            }
            var joint3DPositions: [HandJoint: simd_float3] = [:]
            joint3DPositions[.wrist] = wrist3D

            // ── STEP 3: IK で各指の3D姿勢を復元（fingerDepthBias で沈み込みを抑制）──
            let bias = fingerDepthBias

            func solveChild(parent: HandJoint, child: HandJoint) {
                guard let pPos = joint3DPositions[parent],
                      let cRay = jointRays[child],
                      let rawLen = boneLengths[child] else { return }

                let length = rawLen * handScaleX
                let dotVal = dot(cRay, pPos)
                let disc   = dotVal * dotVal - dot(pPos, pPos) + length * length

                var t: Float
                if disc >= 0 {
                    let sqrtD  = sqrt(disc)
                    let t1     = dotVal + sqrtD
                    let t2     = dotVal - sqrtD
                    let parentT = pPos.z / cRay.z
                    t = abs(t1 - parentT) < abs(t2 - parentT) ? t1 : t2
                    if t < 0 { t = max(t1, t2) }
                } else {
                    t = dotVal
                }

                let rawChildPos = cRay * t
                // 🔑 fingerDepthBias
                let biasedZ = pPos.z + (rawChildPos.z - pPos.z) * bias
                if abs(cRay.z) > 1e-4 {
                    let finalT = biasedZ / cRay.z
                    joint3DPositions[child] = cRay * finalT
                } else {
                    joint3DPositions[child] = rawChildPos
                }
            }

            for finger in fingers {
                for i in 1..<finger.count {
                    solveChild(parent: finger[i-1], child: finger[i])
                }
            }

            // ── STEP 4: エンティティ配置 ──
            for (jointName, pos3D) in joint3DPositions {
                let pair: HandEntityPair
                if let existing = currentState.joints[jointName] {
                    pair = existing
                } else {
                    pair = createJointPair(color: color)
                    leftHead.addChild(pair.leftSceneNode)
                    rightHead.addChild(pair.rightSceneNode)
                    currentState.joints[jointName] = pair
                }
                pair.setEnabled(true)
                pair.leftSceneNode.position  = pos3D
                pair.rightSceneNode.position = pos3D
                let r = jointRadius
                pair.leftSceneNode.scale  = [r, r, r]
                pair.rightSceneNode.scale = [r, r, r]
            }

            var boneIndex = 0
            for finger in fingers {
                for i in 1..<finger.count {
                    guard let startPos = joint3DPositions[finger[i-1]],
                          let endPos   = joint3DPositions[finger[i]] else { continue }
                    let pair: HandEntityPair
                    if boneIndex < currentState.bones.count {
                        pair = currentState.bones[boneIndex]
                    } else {
                        pair = createBonePair(color: color)
                        leftHead.addChild(pair.leftSceneNode)
                        rightHead.addChild(pair.rightSceneNode)
                        currentState.bones.append(pair)
                    }
                    pair.setEnabled(true)
                    updateBoneEntity(pair, from: startPos, to: endPos, radius: boneRadius)
                    boneIndex += 1
                }
            }

            // ── STEP 5: ピンチ判定・レーザー ──
            if let thumb3D = joint3DPositions[.thumbTip],
               let index3D = joint3DPositions[.indexTip],
               let w3D     = joint3DPositions[.wrist] {
                let isPinching = distance(thumb3D, index3D) < 0.03
                if isPinching {
                    let pinchMid  = (thumb3D + index3D) / 2.0
                    let laserDir  = normalize(pinchMid - w3D)
                    let maxDist: Float = 50.0
                    var localEnd  = pinchMid + laserDir * maxDist

                    let rayStart     = leftHead.convert(position: pinchMid, to: nil)
                    let worldEnd     = leftHead.convert(position: localEnd, to: nil)
                    let worldDir     = normalize(worldEnd - rayStart)
                    let hits         = leftView.scene.raycast(
                        from: rayStart, to: rayStart + worldDir * maxDist,
                        query: .nearest, mask: .all, relativeTo: nil)
                    if let hit = hits.first {
                        let dist = distance(rayStart, hit.position)
                        localEnd = pinchMid + laserDir * dist
                        if let idx = targets.firstIndex(where: { $0.left == hit.entity }) {
                            hitTargetIndices.insert(idx)
                        }
                    }

                    let laserPair: HandEntityPair
                    if let ex = currentState.laser {
                        laserPair = ex
                    } else {
                        laserPair = createBonePair(color: ARSystemColor.cyan)
                        leftHead.addChild(laserPair.leftSceneNode)
                        rightHead.addChild(laserPair.rightSceneNode)
                        currentState.laser = laserPair
                    }
                    laserPair.setEnabled(true)
                    updateBoneEntity(laserPair, from: pinchMid, to: localEnd, radius: 0.002)
                }
            }

            // 直接タッチ判定
            if let tipPos = joint3DPositions[.indexTip] {
                let worldPos = leftHead.convert(position: tipPos, to: nil)
                for (i, pair) in targets.enumerated() {
                    if distance(worldPos, pair.left.position(relativeTo: nil)) < 0.08 {
                        hitTargetIndices.insert(i)
                    }
                }
            }
        }

        for (i, pair) in targets.enumerated() {
            let isHit    = hitTargetIndices.contains(i)
            let mat      = UnlitMaterial(color: isHit ? ARSystemColor.systemGreen : ARSystemColor.systemRed)
            pair.left.model?.materials  = [mat]
            pair.right.model?.materials = [mat]
        }
    }

    // MARK: - Helpers
    private func hideAllHandNodes() {
        for state in [leftHandState, rightHandState] {
            state.joints.values.forEach { $0.setEnabled(false) }
            state.bones.forEach          { $0.setEnabled(false) }
            state.laser?.setEnabled(false)
        }
    }

    private func createJointPair(color: ARSystemColor) -> HandEntityPair {
        let mesh = MeshResource.generateSphere(radius: 1.0)
        let mat  = UnlitMaterial(color: color)
        return HandEntityPair(
            leftSceneNode:  ModelEntity(mesh: mesh, materials: [mat]),
            rightSceneNode: ModelEntity(mesh: mesh, materials: [mat]))
    }

    private func createBonePair(color: ARSystemColor) -> HandEntityPair {
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 1.0)
        let mat  = UnlitMaterial(color: color)
        return HandEntityPair(
            leftSceneNode:  ModelEntity(mesh: mesh, materials: [mat]),
            rightSceneNode: ModelEntity(mesh: mesh, materials: [mat]))
    }

    private func updateBoneEntity(_ pair: HandEntityPair,
                                  from: simd_float3,
                                  to: simd_float3,
                                  radius: Float) {
        let height  = distance(from, to)
        let midPos  = (from + to) / 2.0
        pair.leftSceneNode.position  = midPos
        pair.rightSceneNode.position = midPos

        let scale: simd_float3 = [radius, height, radius]
        pair.leftSceneNode.scale  = scale
        pair.rightSceneNode.scale = scale

        let yAxis     = simd_float3(0, 1, 0)
        let direction = normalize(to - from)
        let dotVal    = simd_dot(yAxis, direction)
        let orientation: simd_quatf
        if abs(dotVal) < 0.9999 {
            let axis = normalize(simd_cross(yAxis, direction))
            orientation = simd_quatf(angle: acos(dotVal), axis: axis)
        } else if dotVal < 0 {
            orientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        pair.leftSceneNode.orientation  = orientation
        pair.rightSceneNode.orientation = orientation
    }
}

// MARK: - Camera Preview (macOS)
struct CameraPreviewView: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context: Context) -> VideoPreviewNativeView {
        let v = VideoPreviewNativeView()
        v.previewLayer.session      = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: VideoPreviewNativeView, context: Context) {
        nsView.previewLayer.session = session
    }
}

final class VideoPreviewNativeView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

// MARK: - 2D Hand Skeleton Overlay（SBSカメラ映像上へのフォールバック描画）
struct HandSkeletonView: View {
    var joints:    [HandJoint: CGPoint]
    var isRight:   Bool
    var offsetX:   CGFloat
    var offsetY:   CGFloat
    var scaleX:    CGFloat
    var scaleY:    CGFloat
    var lineWidth: CGFloat
    var jointSize: CGFloat

    private let fingers: [[HandJoint]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    private var handColor: Color { isRight ? .orange : .cyan }
    private var glowColor: Color { isRight ? .red    : .blue }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                skeletonPath(size: geo.size)
                jointDots(size: geo.size)
            }
        }
    }

    @ViewBuilder
    private func skeletonPath(size: CGSize) -> some View {
        Path { path in
            for finger in fingers {
                var first = true
                for joint in finger {
                    guard let np = joints[joint] else { continue }
                    let pt = mapped(np, size: size)
                    if first { path.move(to: pt); first = false }
                    else      { path.addLine(to: pt) }
                }
            }
        }
        .stroke(handColor, style: StrokeStyle(lineWidth: lineWidth,
                                              lineCap: .round, lineJoin: .round))
        .shadow(color: handColor, radius: 8)
        .shadow(color: glowColor, radius: 15)
    }

    @ViewBuilder
    private func jointDots(size: CGSize) -> some View {
        ForEach(Array(joints.keys), id: \.self) { joint in
            if let np = joints[joint] {
                Circle()
                    .fill(Color.white)
                    .frame(width: jointSize, height: jointSize)
                    .position(mapped(np, size: size))
                    .shadow(color: handColor, radius: 5)
            }
        }
    }

    private func mapped(_ np: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: np.x * size.width  * scaleX + offsetX,
                y: np.y * size.height * scaleY + offsetY)
    }
}

// MARK: - Main SBS Camera View
struct USBCameraModeView: View {
    @Binding var currentMode: AppState

    @StateObject private var cameraManager = CameraManager()
    @StateObject private var calibration   = CalibrationViewModel()
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            HStack(spacing: 0) {
                eyeView(params: calibration.leftParams,  isLeft: true)
                eyeView(params: calibration.rightParams, isLeft: false)
            }
            .ignoresSafeArea()

            gearButton
            if showSettings { settingsPanelOverlay }
        }
        .onAppear  { cameraManager.checkPermissions() }
        .onDisappear { cameraManager.session.stopRunning() }
    }

    @ViewBuilder
    private var gearButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Button { withAnimation { showSettings.toggle() } } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding()
            }
        }
    }

    @ViewBuilder
    private var settingsPanelOverlay: some View {
        HStack {
            CalibrationPanelView(
                calibration: calibration,
                onClose: { withAnimation { showSettings = false } }
            )
            .transition(.move(edge: .leading).combined(with: .opacity))
            Spacer()
        }
    }

    @ViewBuilder
    private func eyeView(params: CalibrationParams, isLeft: Bool) -> some View {
        let parallax: CGFloat = isLeft
            ? -calibration.leftParams.leftParallax
            :  calibration.rightParams.rightParallax

        ZStack {
            CameraPreviewView(session: cameraManager.session)
                .scaleEffect(params.videoScale)
                .offset(x: params.videoOffsetX, y: params.videoOffsetY)

            ForEach(cameraManager.hands) { hand in
                HandSkeletonView(
                    joints:    hand.joints,
                    isRight:   hand.isRight,
                    offsetX:   params.offsetX + parallax,
                    offsetY:   params.offsetY,
                    scaleX:    params.scaleX,
                    scaleY:    params.scaleY,
                    lineWidth: 4.0,
                    jointSize: 10.0
                )
                .scaleEffect(params.videoScale)
                .offset(x: params.videoOffsetX, y: params.videoOffsetY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - Calibration Panel
private struct CalibrationPanelView: View {
    @ObservedObject var calibration: CalibrationViewModel
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                headerSection
                videoOffsetSection
                Divider()
                parallaxSection
                Divider()
                handTransformSection
                resetAndCloseButtons
            }
            .font(.caption)
            .padding()
        }
        .frame(width: 260)
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .foregroundColor(.white)
        .padding()
    }

    @ViewBuilder private var headerSection: some View {
        Text("Calibration (L/R Shared)")
            .font(.headline)
            .foregroundColor(.green)
    }

    @ViewBuilder private var videoOffsetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Video Offset X").foregroundColor(.yellow)
            sliderRow(label: "Left",  value: $calibration.leftParams.videoOffsetX,  range: -500...500)
            sliderRow(label: "Right", value: $calibration.rightParams.videoOffsetX, range: -500...500)
        }
    }

    @ViewBuilder private var parallaxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hand Depth Parallax").foregroundColor(.yellow)
            sliderRow(label: "Left",  value: $calibration.leftParams.leftParallax,   range: -100...100)
            sliderRow(label: "Right", value: $calibration.rightParams.rightParallax, range: -100...100)
        }
    }

    @ViewBuilder private var handTransformSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hand Transform").foregroundColor(.yellow)

            HStack {
                Text("Scale X/Y: \(calibration.leftParams.scaleX, specifier: "%.2f")")
                Slider(value: $calibration.leftParams.scaleX, in: 0.1...3.0)
                    .onChange(of: calibration.leftParams.scaleX) { _, v in
                        calibration.leftParams.scaleY   = v
                        calibration.rightParams.scaleX  = v
                        calibration.rightParams.scaleY  = v
                    }
            }

            HStack {
                Text("Offset X: \(Int(calibration.leftParams.offsetX))")
                Slider(value: $calibration.leftParams.offsetX, in: -500...500)
                    .onChange(of: calibration.leftParams.offsetX) { _, v in
                        calibration.rightParams.offsetX = v
                    }
            }

            HStack {
                Text("Offset Y: \(Int(calibration.leftParams.offsetY))")
                Slider(value: $calibration.leftParams.offsetY, in: -500...500)
                    .onChange(of: calibration.leftParams.offsetY) { _, v in
                        calibration.rightParams.offsetY = v
                    }
            }
        }
    }

    @ViewBuilder private var resetAndCloseButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Reset to Vision (no transforms)") {
                calibration.resetHandTransforms()
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 4)

            Button("Close Panel", action: onClose)
                .padding(.top, 6)
        }
    }

    private func sliderRow(label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        HStack {
            Text("\(label): \(Int(value.wrappedValue))")
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
        }
    }
}
