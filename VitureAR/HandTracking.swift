//
//  HandTracking.swift
//  VitureAR
//
//  Created by Shun Matsumoto on 2026/04/07.
//
import Foundation
internal import AVFoundation
import Vision
import RealityKit
import SwiftUI
import Combine

#if os(macOS)
import AppKit
typealias ARSystemColor = NSColor
#else
import UIKit
typealias ARSystemColor = UIColor
#endif

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
class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var session = AVCaptureSession()
    @Published var hands: [HandData] = []
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "videoQueue", qos: .userInteractive)
    
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { self?.setupCamera() }
                }
            }
        default:
            print("Camera Access Denied")
        }
    }
    
    private func getVITUREcamera() -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [.external, .builtInWideAngleCamera]
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let devices = discoverySession.devices
        
        #if os(macOS)
        if let externalCamera = devices.first(where: {
            if #available(macOS 14.0, *) {
                return $0.deviceType == .external
            } else {
                return $0.deviceType == .externalUnknown || $0.localizedName.localizedCaseInsensitiveContains("USB")
            }
        }) {
            return externalCamera
        }
        #else
        if #available(iOS 17.0, *) {
            if let externalCamera = devices.first(where: { $0.deviceType == .external }) {
                return externalCamera
            }
        }
        #endif
        
        if let builtInCamera = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            return builtInCamera
        }
        return nil
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        guard let device = getVITUREcamera() else {
            session.commitConfiguration()
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input) }
            
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
            
            if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        } catch {
            print("Camera Error: \(error)")
        }
        session.commitConfiguration()
        DispatchQueue.global(qos: .background).async { self.session.startRunning() }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([handPoseRequest])
            if let observations = handPoseRequest.results {
                processHandPose(observations: observations)
            }
        } catch {
            print("Vision Error: \(error)")
        }
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
        for observation in observations {
            var points: [HandJoint: CGPoint] = [:]
            var isRight = false
            
            if #available(macOS 11.0, iOS 14.0, *) {
                isRight = observation.chirality == .left
            }
            
            do {
                let recognizedPoints = try observation.recognizedPoints(.all)
                for (key, point) in recognizedPoints {
                    if point.confidence > 0.3 {
                        points[key] = CGPoint(x: 1.0 - point.location.x, y: 1.0 - point.location.y)
                    }
                }
                let indexTip = points[HandJoint.indexTip]
                let distance = getDepthDistance(joints: points, indexTip: indexTip)
                let centerX = points[HandJoint.wrist]?.x ?? 0.5
                tempHands.append(TempHand(isRight: isRight, joints: points, indexTip: indexTip, distance: distance, centerX: centerX))
            } catch {}
        }
        
        if tempHands.count == 2 {
            if tempHands[0].centerX > tempHands[1].centerX {
                tempHands[0].isRight = true; tempHands[1].isRight = false
            } else {
                tempHands[0].isRight = false; tempHands[1].isRight = true
            }
        }
        
        let detectedHands = tempHands.map { HandData(isRight: $0.isRight, joints: $0.joints, indexTip: $0.indexTip, distance: $0.distance) }
        DispatchQueue.main.async { self.hands = detectedHands }
    }
    
    private func getDepthDistance(joints: [HandJoint: CGPoint], indexTip: CGPoint?) -> CGFloat {
        guard let wrist = joints[HandJoint.wrist], let middleMCP = joints[HandJoint.middleMCP] else { return 1.0 }
        let dx = wrist.x - middleMCP.x
        let dy = wrist.y - middleMCP.y
        return 1.0 / max(sqrt(dx*dx + dy*dy), 0.01)
    }
}

// MARK: - 3D Hand Tracking Coordinator (RealityKit)
class HandTrackingCoordinator: ObservableObject {
    weak var leftView: ARView?
    weak var rightView: ARView?
    weak var spacialCoordinator: SpacialCoordinator?
    var cameraManager: CameraManager?
    
    @Published var videoScale: Float = 1.90
    @Published var videoOffsetX: Float = 0.0
    @Published var videoOffsetY: Float = -368.0
    
    @Published var handScaleX: Float = 1.0
    @Published var handScaleY: Float = 1.0
    @Published var handOffsetX: Float = 0.0
    @Published var handOffsetY: Float = 0.0
    
    @Published var handBaseZ: Float = 0.0
    @Published var handDepthMultiplier: Float = 0.025
    @Published var jointRadius: Float = 0.006
    @Published var boneRadius: Float = 0.003
    
    private let fingers: [[HandJoint]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]
    
    // 🌟 人間の平均的な手の骨の長さ（メートル単位）
    private let boneLengths: [HandJoint: Float] = [
        .thumbCMC: 0.04, .thumbMP: 0.03, .thumbIP: 0.03, .thumbTip: 0.02,
        .indexMCP: 0.07, .indexPIP: 0.04, .indexDIP: 0.025, .indexTip: 0.02,
        .middleMCP: 0.075, .middlePIP: 0.045, .middleDIP: 0.025, .middleTip: 0.02,
        .ringMCP: 0.07, .ringPIP: 0.04, .ringDIP: 0.025, .ringTip: 0.02,
        .littleMCP: 0.06, .littlePIP: 0.03, .littleDIP: 0.015, .littleTip: 0.015
    ]
    
    struct TargetPair { let left: ModelEntity; let right: ModelEntity }
    var targets: [TargetPair] = []
    
    class HandState {
        var joints: [HandJoint: HandEntityPair] = [:]
        var bones: [HandEntityPair] = []
        var laser: HandEntityPair?
    }
    var leftHandState = HandState()
    var rightHandState = HandState()
    
    struct HandEntityPair {
        let leftSceneNode: ModelEntity
        let rightSceneNode: ModelEntity
        func setEnabled(_ isEnabled: Bool) {
            leftSceneNode.isEnabled = isEnabled
            rightSceneNode.isEnabled = isEnabled
        }
    }
    
    private var isSetupDone = false
    private var updateSub: Cancellable?
    
    func setupIfNeeded(leftView: ARView, rightView: ARView, spacial: SpacialCoordinator) {
        guard !isSetupDone else { return }
        self.leftView = leftView; self.rightView = rightView; self.spacialCoordinator = spacial
        let leftAnchor = AnchorEntity(world: .zero)
        let rightAnchor = AnchorEntity(world: .zero)
        leftView.scene.addAnchor(leftAnchor); rightView.scene.addAnchor(rightAnchor)
        setupTargets(leftAnchor: leftAnchor, rightAnchor: rightAnchor)
        updateSub = leftView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in self?.updateHandTracking() }
        isSetupDone = true
    }
    
    private func setupTargets(leftAnchor: AnchorEntity, rightAnchor: AnchorEntity) {
        let shapesData: [(pos: simd_float3, mesh: MeshResource, color: ARSystemColor)] = [
            (simd_float3(-0.6, 0.0, -2.0), MeshResource.generateBox(size: 0.3), ARSystemColor.systemRed),
            (simd_float3( 0.0, 0.0, -2.0), MeshResource.generateSphere(radius: 0.2), ARSystemColor.systemBlue),
            (simd_float3( 0.6, 0.0, -2.0), MeshResource.generateCylinder(height: 0.4, radius: 0.15), ARSystemColor.systemGreen)
        ]
        for item in shapesData {
            let mat = SimpleMaterial(color: item.color, isMetallic: false)
            let leftEntity = ModelEntity(mesh: item.mesh, materials: [mat])
            leftEntity.position = item.pos; leftEntity.generateCollisionShapes(recursive: false)
            leftAnchor.addChild(leftEntity)
            let rightEntity = ModelEntity(mesh: item.mesh, materials: [mat])
            rightEntity.position = item.pos; rightAnchor.addChild(rightEntity)
            targets.append(TargetPair(left: leftEntity, right: rightEntity))
        }
    }
    
    private func updateHandTracking() {
        guard let hands = cameraManager?.hands, let leftView = leftView,
              let leftHead = spacialCoordinator?.leftHead, let rightHead = spacialCoordinator?.rightHead else { return }
        
        hideAllHandNodes()
        var hitTargetIndices: Set<Int> = []
        let fovValue = spacialCoordinator?.fieldOfView ?? 46.0
        
        let baseWidth: Float = 1920.0; let baseHeight: Float = 1080.0
        let pxToMeters: Float = 1.0 / 1000.0
        let screenWidthMeters = baseWidth * pxToMeters
        let fovRad = Float(fovValue) * .pi / 180.0
        let screenZ = -(screenWidthMeters / 2.0) / tan(fovRad / 2.0)
        
        for hand in hands {
            let currentState = hand.isRight ? rightHandState : leftHandState
            let color: ARSystemColor = hand.isRight ? .orange : .cyan
            
            // 🌟 1. 2D座標を「カメラ中心から伸びる3Dのレイ（光線）」に変換する
            var jointRays: [HandJoint: simd_float3] = [:]
            for (jointName, point) in hand.joints {
                let px = Float(point.x) * baseWidth; let py = Float(point.y) * baseHeight
                let adjustedPx = (px * handScaleX) + handOffsetX
                let adjustedPy = (py * handScaleY) + handOffsetY
                
                var cx = adjustedPx - (baseWidth / 2.0); var cy = adjustedPy - (baseHeight / 2.0)
                cx = (cx * videoScale) + videoOffsetX; cy = (cy * videoScale) + videoOffsetY
                
                let localX = cx * pxToMeters; let localY = -cy * pxToMeters
                // カメラから関節に向かう光線（レイ）を作成
                jointRays[jointName] = normalize(simd_float3(localX, localY, screenZ))
            }
            
            var joint3DPositions: [HandJoint: simd_float3] = [:]
            
            // 🌟 2. 基準となる手首(Wrist)の正確な3D位置を計算
            var wrist3D: simd_float3 = [0, 0, screenZ]
            if let rayWrist = jointRays[.wrist], let rayMidMCP = jointRays[.middleMCP] {
                // 手首から中指の付け根までの実際の距離(約8cm)から、手の奥行き(Z)を計算
                let targetLength: Float = 0.08 * handScaleX
                let distRays = distance(rayWrist, rayMidMCP)
                let t = targetLength / max(distRays, 0.001)
                
                wrist3D = rayWrist * t
                wrist3D.z += handBaseZ // ユーザーのスライダー調整を反映
                wrist3D = rayWrist * (wrist3D.z / rayWrist.z) // レイの上に乗せ直す
            }
            joint3DPositions[.wrist] = wrist3D
            
            // 🌟 3. 骨の長さを使った逆運動学(IK)で、指の3D姿勢を完全復元する関数
            func solveChild(parent: HandJoint, child: HandJoint) {
                guard let pPos = joint3DPositions[parent], let cRay = jointRays[child],
                      let rawLength = boneLengths[child] else { return }
                
                let length = rawLength * handScaleX
                let dotVal = dot(cRay, pPos)
                let discriminant = dotVal * dotVal - dot(pPos, pPos) + length * length
                
                var t: Float = 0
                if discriminant >= 0 {
                    // レイと骨の長さが交差する2点のうち、親のZ座標に近い方を採用（自然な指の曲がり方を再現）
                    let t1 = dotVal + sqrt(discriminant); let t2 = dotVal - sqrt(discriminant)
                    let parentT = pPos.z / cRay.z
                    t = abs(t1 - parentT) < abs(t2 - parentT) ? t1 : t2
                } else {
                    // 万が一誤差で届かない場合は、レイ上で最も近い点を採用
                    t = dotVal
                }
                joint3DPositions[child] = cRay * t
            }
            
            // 親関節から子関節へと順番に3D座標を解いていく
            for finger in fingers {
                for i in 0..<(finger.count - 1) {
                    solveChild(parent: finger[i], child: finger[i+1])
                }
            }
            
            // 4. 計算した正確な3D座標にモデルを配置
            for (jointName, pos3D) in joint3DPositions {
                let pair: HandEntityPair
                if let existing = currentState.joints[jointName] { pair = existing } else {
                    pair = createJointPair(color: color)
                    leftHead.addChild(pair.leftSceneNode); rightHead.addChild(pair.rightSceneNode)
                    currentState.joints[jointName] = pair
                }
                pair.setEnabled(true)
                pair.leftSceneNode.position = pos3D; pair.rightSceneNode.position = pos3D
                pair.leftSceneNode.scale = [jointRadius, jointRadius, jointRadius]
                pair.rightSceneNode.scale = [jointRadius, jointRadius, jointRadius]
            }
            
            var boneIndex = 0
            for finger in fingers {
                for i in 0..<(finger.count - 1) {
                    if let startPos = joint3DPositions[finger[i]], let endPos = joint3DPositions[finger[i+1]] {
                        let pair: HandEntityPair
                        if boneIndex < currentState.bones.count { pair = currentState.bones[boneIndex] } else {
                            pair = createBonePair(color: color)
                            leftHead.addChild(pair.leftSceneNode); rightHead.addChild(pair.rightSceneNode)
                            currentState.bones.append(pair)
                        }
                        pair.setEnabled(true)
                        updateBoneEntity(pair, from: startPos, to: endPos, radius: boneRadius)
                        boneIndex += 1
                    }
                }
            }
            
            // 🌟 5. ピンチ判定も「完全に正確な3Dの物理距離」で判定！
            if let thumb3D = joint3DPositions[.thumbTip], let index3D = joint3DPositions[.indexTip], let wrist3D = joint3DPositions[.wrist] {
                // 親指と人差し指の実際の距離が3cm未満ならピンチ（どんな角度から見ても正確！）
                let isPinching = distance(thumb3D, index3D) < 0.03
                
                if isPinching {
                    let pinchMid = (thumb3D + index3D) / 2.0
                    let laserDir = normalize(pinchMid - wrist3D)
                    let maxLaserDist: Float = 50.0
                    let localStart = pinchMid
                    var localEnd = pinchMid + laserDir * maxLaserDist
                    
                    let rayStart = leftHead.convert(position: localStart, to: nil)
                    let worldEndTarget = leftHead.convert(position: localEnd, to: nil)
                    let rayDir = normalize(worldEndTarget - rayStart)
                    
                    let hits = leftView.scene.raycast(from: rayStart, to: rayStart + rayDir * maxLaserDist, query: .nearest, mask: .all, relativeTo: nil)
                    if let firstHit = hits.first {
                        let dist = distance(rayStart, firstHit.position)
                        localEnd = localStart + laserDir * dist
                        if let targetIdx = targets.firstIndex(where: { $0.left == firstHit.entity }) {
                            hitTargetIndices.insert(targetIdx)
                        }
                    }
                    
                    let laserPair: HandEntityPair
                    if let existing = currentState.laser { laserPair = existing } else {
                        laserPair = createBonePair(color: ARSystemColor.cyan)
                        leftHead.addChild(laserPair.leftSceneNode); rightHead.addChild(laserPair.rightSceneNode)
                        currentState.laser = laserPair
                    }
                    laserPair.setEnabled(true)
                    updateBoneEntity(laserPair, from: localStart, to: localEnd, radius: 0.002)
                }
            }
            
            // 直接タッチの判定も正確な3Dで
            if let indexTipPos = joint3DPositions[.indexTip] {
                let worldPos = leftHead.convert(position: indexTipPos, to: nil)
                for (i, pair) in targets.enumerated() {
                    if distance(worldPos, pair.left.position(relativeTo: nil)) < 0.08 {
                        hitTargetIndices.insert(i)
                    }
                }
            }
        }
        
        for (index, pair) in targets.enumerated() {
            let isHit = hitTargetIndices.contains(index)
            let color: ARSystemColor = isHit ? .systemGreen : .systemRed
            var mat = UnlitMaterial(color: color)
            pair.left.model?.materials = [mat]
            pair.right.model?.materials = [mat]
        }
    }
    
    private func hideAllHandNodes() {
        [leftHandState, rightHandState].forEach { state in
            state.joints.values.forEach { $0.setEnabled(false) }
            state.bones.forEach { $0.setEnabled(false) }
            state.laser?.setEnabled(false)
        }
    }
    
    private func createJointPair(color: ARSystemColor) -> HandEntityPair {
        let mesh = MeshResource.generateSphere(radius: 1.0)
        return HandEntityPair(leftSceneNode: ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]),
                              rightSceneNode: ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]))
    }
    
    private func createBonePair(color: ARSystemColor) -> HandEntityPair {
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 1.0)
        return HandEntityPair(leftSceneNode: ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]),
                              rightSceneNode: ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)]))
    }
    
    private func updateBoneEntity(_ pair: HandEntityPair, from: simd_float3, to: simd_float3, radius: Float) {
        let height = distance(from, to)
        let midPos = (from + to) / 2.0
        pair.leftSceneNode.position = midPos; pair.rightSceneNode.position = midPos
        let scale: simd_float3 = [radius, height, radius]
        pair.leftSceneNode.scale = scale; pair.rightSceneNode.scale = scale
        
        let yAxis = simd_float3(0, 1, 0)
        let direction = normalize(to - from)
        let dotVal = simd_dot(yAxis, direction)
        
        let orientation: simd_quatf
        if abs(dotVal) < 0.9999 {
            let axis = normalize(simd_cross(yAxis, direction))
            orientation = simd_quatf(angle: acos(dotVal), axis: axis)
        } else if dotVal < 0 {
            orientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        pair.leftSceneNode.orientation = orientation; pair.rightSceneNode.orientation = orientation
    }
}
