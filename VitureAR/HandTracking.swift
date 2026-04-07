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
import AppKit

struct HandData: Identifiable {
    let id = UUID()
    var isRight: Bool
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    let indexTip: CGPoint?
    let distance: CGFloat
}

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var session = AVCaptureSession()
    @Published var hands: [HandData] = []
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "videoQueue", qos: .userInteractive)
    
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2 // Both Hands can be Detected
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
        
        if let externalCamera = devices.first(where: {
            return $0.deviceType == .external
        }) {
            print("External Camera Selected: \(externalCamera.localizedName)")
            return externalCamera
        }
        
        if let builtInCamera = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            print("USB Camera not found: \(builtInCamera.localizedName)")
            return builtInCamera
        }
        return nil
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        
        guard let device = getVITUREcamera() else {
            print("Camera Not Found")
            session.commitConfiguration()
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            
            if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
            
        } catch {
            print("Camera Error: \(error.localizedDescription)")
        }
        
        session.commitConfiguration()
        
        DispatchQueue.global(qos: .background).async {
            self.session.startRunning()
        }
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
            let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
            let indexTip: CGPoint?
            let distance: CGFloat
            let centerX: CGFloat
        }
        
        var tempHands: [TempHand] = []
        
        for observation in observations {
            var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            var isRight = false
            
            if #available(macOS 11.0, iOS 14.0, *) {
                isRight = observation.chirality == .left // Mirroring
            }
            
            do {
                let recognizedPoints = try observation.recognizedPoints(.all)
                for (key, point) in recognizedPoints {
                    if point.confidence > 0.3 {
                        points[key] = CGPoint(
                            x: 1.0 - point.location.x,
                            y: 1.0 - point.location.y
                        )
                    }
                }
                
                let indexTip = points[.indexTip]
                let distance = getDepthDistance(joints: points, indexTip: indexTip)
                let centerX = points[.wrist]?.x ?? 0.5
                
                tempHands.append(TempHand(isRight: isRight, joints: points, indexTip: indexTip, distance: distance, centerX: centerX))
                
            } catch {
                print("Error acquiring Hands")
            }
        }
        
        // Stabilize
        if tempHands.count == 2 {
            if tempHands[0].centerX > tempHands[1].centerX {
                tempHands[0].isRight = true
                tempHands[1].isRight = false
            } else {
                tempHands[0].isRight = false
                tempHands[1].isRight = true
            }
        }
        
        let detectedHands = tempHands.map { temp in
            HandData(
                isRight: temp.isRight,
                joints: temp.joints,
                indexTip: temp.indexTip,
                distance: temp.distance
            )
        }
        
        DispatchQueue.main.async {
            self.hands = detectedHands
        }
    }
    
    private func getDepthDistance(joints: [VNHumanHandPoseObservation.JointName: CGPoint], indexTip: CGPoint?) -> CGFloat {
        guard let wrist = joints[.wrist], let middleMCP = joints[.middleMCP] else { return 1.0 }
        let dx = wrist.x - middleMCP.x
        let dy = wrist.y - middleMCP.y
        let size = sqrt(dx*dx + dy*dy)
        return 1.0 / max(size, 0.01)
    }
}

// MARK: - 3D Hand Tracking Coordinator (RealityKit)
class HandTrackingCoordinator: ObservableObject {
    weak var leftView: ARView?
    weak var rightView: ARView?
    weak var spacialCoordinator: SpacialCoordinator?
    var cameraManager: CameraManager?
    
    // ハンドトラッキング用調整パラメータ
    @Published var handScaleX: Float = 1.55
    @Published var handScaleY: Float = 1.55
    @Published var handOffsetX: Float = 0.0
    @Published var handOffsetY: Float = -0.31
    @Published var handBaseZ: Float = -0.48
    @Published var handDepthMultiplier: Float = 0.025
    @Published var jointRadius: Float = 0.006
    @Published var boneRadius: Float = 0.003
    
    private let fingers: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]
    
    struct TargetPair {
        let left: ModelEntity
        let right: ModelEntity
    }
    var targets: [TargetPair] = []
    
    class HandState {
        var joints: [VNHumanHandPoseObservation.JointName: HandEntityPair] = [:]
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
    
    // MARK: - Setup
    func setupIfNeeded(leftView: ARView, rightView: ARView, spacial: SpacialCoordinator) {
        guard !isSetupDone else { return }
        self.leftView = leftView
        self.rightView = rightView
        self.spacialCoordinator = spacial
        
        let leftAnchor = AnchorEntity(world: .zero)
        let rightAnchor = AnchorEntity(world: .zero)
        leftView.scene.addAnchor(leftAnchor)
        rightView.scene.addAnchor(rightAnchor)
        
        setupTargets(leftAnchor: leftAnchor, rightAnchor: rightAnchor)
        
        updateSub = leftView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            self?.updateHandTracking()
        }
        
        isSetupDone = true
    }
    
    private func setupTargets(leftAnchor: AnchorEntity, rightAnchor: AnchorEntity) {
        let shapesData: [(pos: simd_float3, mesh: MeshResource, color: SystemColor)] = [
            (simd_float3(-0.6, 0.0, -2.0), .generateBox(size: 0.3), .systemRed),
            (simd_float3( 0.0, 0.0, -2.0), .generateSphere(radius: 0.2), .systemBlue),
            (simd_float3( 0.6, 0.0, -2.0), .generateCylinder(height: 0.4, radius: 0.15), .systemGreen)
        ]
        
        for item in shapesData {
            let mat = SimpleMaterial(color: item.color, isMetallic: false)
            
            let leftEntity = ModelEntity(mesh: item.mesh, materials: [mat])
            leftEntity.position = item.pos
            leftEntity.generateCollisionShapes(recursive: false)
            leftAnchor.addChild(leftEntity)
            
            let rightEntity = ModelEntity(mesh: item.mesh, materials: [mat])
            rightEntity.position = item.pos
            rightAnchor.addChild(rightEntity)
            
            targets.append(TargetPair(left: leftEntity, right: rightEntity))
        }
    }
    
    // MARK: - Update Loop
    private func updateHandTracking() {
        guard let hands = cameraManager?.hands,
              let leftView = leftView,
              let leftHead = spacialCoordinator?.leftHead,
              let rightHead = spacialCoordinator?.rightHead else { return }
        
        hideAllHandNodes()
        var hitTargetIndices: Set<Int> = []
        let fovValue = spacialCoordinator?.fieldOfView ?? 46.0
        
        for hand in hands {
            let zDist: Float = handBaseZ - (Float(hand.distance) * handDepthMultiplier)
            let fovRad = Float(fovValue) * Float.pi / 180.0
            let aspect: Float = 16.0 / 9.0
            let halfHeight = abs(zDist) * tan(fovRad / 2.0)
            let halfWidth = halfHeight * aspect
            
            let currentState = hand.isRight ? rightHandState : leftHandState
            let color = hand.isRight ? SystemColor.orange : SystemColor.cyan
            var joint3DPositions: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            
            // 1. ジョイントの配置
            for (jointName, point) in hand.joints {
                let adjustedX = (Float(point.x) - 0.5) * handScaleX + handOffsetX
                let adjustedY = (Float(point.y) - 0.5) * handScaleY + handOffsetY
                
                let localX = adjustedX * 2.0 * halfWidth
                let localY = -adjustedY * 2.0 * halfHeight
                let pos3D = simd_float3(localX, localY, zDist)
                joint3DPositions[jointName] = pos3D
                
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
                pair.leftSceneNode.position = pos3D
                pair.rightSceneNode.position = pos3D
                pair.leftSceneNode.scale = [jointRadius, jointRadius, jointRadius]
                pair.rightSceneNode.scale = [jointRadius, jointRadius, jointRadius]
            }
            
            // 2. ボーンの描画
            var boneIndex = 0
            for finger in fingers {
                for i in 0..<(finger.count - 1) {
                    let startJoint = finger[i]
                    let endJoint = finger[i+1]
                    
                    if let startPos = joint3DPositions[startJoint], let endPos = joint3DPositions[endJoint] {
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
            }
            
            // 3. ピンチジェスチャー＆レーザー判定
            var isPinching = false
            if let thumb2D = hand.joints[.thumbTip], let index2D = hand.joints[.indexTip] {
                let dx = thumb2D.x - index2D.x
                let dy = thumb2D.y - index2D.y
                isPinching = sqrt(dx*dx + dy*dy) < 0.05
            }
            
            if isPinching,
               let thumb3D = joint3DPositions[.thumbTip],
               let index3D = joint3DPositions[.indexTip],
               let wrist3D = joint3DPositions[.wrist] {
                
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
                if let existing = currentState.laser {
                    laserPair = existing
                } else {
                    laserPair = createBonePair(color: .cyan)
                    leftHead.addChild(laserPair.leftSceneNode)
                    rightHead.addChild(laserPair.rightSceneNode)
                    currentState.laser = laserPair
                }
                laserPair.setEnabled(true)
                updateBoneEntity(laserPair, from: localStart, to: localEnd, radius: 0.002)
            }
            
            // 4. 直接触った場合の判定
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
            let color: SystemColor = isHit ? .systemGreen : .systemRed
            let mat = UnlitMaterial(color: color)
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
    
    private func createJointPair(color: SystemColor) -> HandEntityPair {
        let mesh = MeshResource.generateSphere(radius: 1.0)
        let mat = UnlitMaterial(color: color)
        return HandEntityPair(leftSceneNode: ModelEntity(mesh: mesh, materials: [mat]),
                              rightSceneNode: ModelEntity(mesh: mesh, materials: [mat]))
    }
    
    private func createBonePair(color: SystemColor) -> HandEntityPair {
        let mesh = MeshResource.generateCylinder(height: 1.0, radius: 1.0)
        let mat = UnlitMaterial(color: color)
        return HandEntityPair(leftSceneNode: ModelEntity(mesh: mesh, materials: [mat]),
                              rightSceneNode: ModelEntity(mesh: mesh, materials: [mat]))
    }
    
    private func updateBoneEntity(_ pair: HandEntityPair, from: simd_float3, to: simd_float3, radius: Float) {
        let height = distance(from, to)
        let midPos = (from + to) / 2.0
        pair.leftSceneNode.position = midPos
        pair.rightSceneNode.position = midPos
        
        let scale: simd_float3 = [radius, height, radius]
        pair.leftSceneNode.scale = scale
        pair.rightSceneNode.scale = scale
        
        let yAxis = simd_float3(0, 1, 0)
        let direction = normalize(to - from)
        let dot = simd_dot(yAxis, direction)
        
        let orientation: simd_quatf
        if abs(dot) < 0.9999 {
            let axis = normalize(simd_cross(yAxis, direction))
            let angle = acos(dot)
            orientation = simd_quatf(angle: angle, axis: axis)
        } else if dot < 0 {
            orientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        
        pair.leftSceneNode.orientation = orientation
        pair.rightSceneNode.orientation = orientation
    }
}

// MARK: - 2D Hand Skeleton View (SwiftUI)
struct HandSkeletonView: View {
    var joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    var isRight: Bool
    
    var offsetX: CGFloat
    var offsetY: CGFloat
    var scaleX: CGFloat
    var scaleY: CGFloat
    var lineWidth: CGFloat
    var jointSize: CGFloat
    
    let fingers: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]
    
    var handColor: Color { return isRight ? .orange : .cyan }
    var glowColor: Color { return isRight ? .red : .blue }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    for finger in fingers {
                        var isFirstPoint = true
                        for jointName in finger {
                            if let normalizedPoint = joints[jointName] {
                                let point = CGPoint(
                                    x: (normalizedPoint.x * geometry.size.width * scaleX) + offsetX,
                                    y: (normalizedPoint.y * geometry.size.height * scaleY) + offsetY
                                )
                                if isFirstPoint {
                                    path.move(to: point)
                                    isFirstPoint = false
                                } else {
                                    path.addLine(to: point)
                                }
                            }
                        }
                    }
                }
                .stroke(handColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: handColor, radius: 8, x: 0, y: 0)
                .shadow(color: glowColor, radius: 15, x: 0, y: 0)
                
                ForEach(Array(joints.keys), id: \.self) { jointName in
                    if let normalizedPoint = joints[jointName] {
                        let point = CGPoint(
                            x: (normalizedPoint.x * geometry.size.width * scaleX) + offsetX,
                            y: (normalizedPoint.y * geometry.size.height * scaleY) + offsetY
                        )
                        Circle()
                            .fill(Color.white)
                            .frame(width: jointSize, height: jointSize)
                            .position(point)
                            .shadow(color: handColor, radius: 5)
                    }
                }
            }
        }
    }
}
