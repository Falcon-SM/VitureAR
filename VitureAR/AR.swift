#if os(macOS)
import AppKit
internal import AVFoundation
typealias SystemColor = NSColor
#else
import UIKit
typealias SystemColor = UIColor
#endif

import SwiftUI
import SceneKit
import simd
import Combine
import Vision

// MARK: - SCNView ラッパー
struct RawSceneView: NSViewRepresentable {
    let scene:      SCNScene
    let cameraNode: SCNNode
    let delegate:   SCNSceneRendererDelegate?

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene                      = scene
        v.pointOfView                = cameraNode
        v.delegate                   = delegate
        v.autoenablesDefaultLighting = false
        v.allowsCameraControl        = false
        v.rendersContinuously        = true
        v.backgroundColor            = .clear
        return v
    }
    func updateNSView(_ nsView: SCNView, context: Context) {}
}

// MARK: - AR Scene Delegate
class ARSceneDelegate: NSObject, SCNSceneRendererDelegate, ObservableObject {
    var headNode: SCNNode?
    var leftCameraNode: SCNNode?
    var rightCameraNode: SCNNode?
    
    // ── ハンドトラッキング連動用 ──
    var cameraManager: CameraManager?
    
    var targetNodes: [SCNNode] = []
    
    private var leftJointNodes: [VNHumanHandPoseObservation.JointName: SCNNode] = [:]
    private var rightJointNodes: [VNHumanHandPoseObservation.JointName: SCNNode] = [:]
    private var leftBoneNodes: [SCNNode] = []
    private var rightBoneNodes: [SCNNode] = []
    
    private var leftLaserNode: SCNNode?
    private var rightLaserNode: SCNNode?

    private let lock = NSLock()
    private var latestQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var latestP = simd_float3(0, 0, 0)
    private var smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothP = simd_float3(0, 0, 0)
    private var referenceQ: simd_quatf?
    private var referenceP: simd_float3 = .zero
    private var shouldReset = true
    
    // 改善点③: 遅延をなくし、Swim現象（空間の滑り）を防ぐため1.0に変更。
    // もしIMUのブレが気になる場合のみ、0.95などに少し下げてください。
        private let ALPHA: Float = 0.4

    // ── パラメータ群 ──
    @Published var ipd: Float = 0.063 { // 初期値を63mmに変更
        didSet { updateCameraPositions() }
    }
    @Published var fieldOfView: CGFloat = 46.0 {
        didSet {
            leftCameraNode?.camera?.fieldOfView = fieldOfView
            rightCameraNode?.camera?.fieldOfView = fieldOfView
        }
    }
    @Published var debugPosition: simd_float3 = .zero
    
    // 改善点⑤: 現実の移動量とVRの移動量が合わない場合のスケール調整用
    @Published var positionScale: Float = 1.0
    
    // ハンドトラッキング用調整パラメータ
    @Published var handScaleX: Float = 1.55
    @Published var handScaleY: Float = 1.55
    @Published var handOffsetX: Float = 0.0
    @Published var handOffsetY: Float = -0.31
    @Published var handBaseZ: Float = -0.48
    @Published var handDepthMultiplier: Float = 0.025
    @Published var jointRadius: CGFloat = 0.006
    @Published var boneRadius: CGFloat = 0.003
    
    private let fingers: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.wrist, .indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.wrist, .middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.wrist, .ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.wrist, .littleMCP, .littlePIP, .littleDIP, .littleTip]
    ]

    override init() {
        super.init()
    }

    func recenter() {
        lock.lock()
        shouldReset = true
        lock.unlock()
    }

    func updatePose(x: Float, y: Float, z: Float, qw: Float, qx: Float, qy: Float, qz: Float) {
        let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
        let p = simd_float3(x, y, z)
        lock.lock()
        latestQ = q
        latestP = p
        lock.unlock()
    }
    
    // 改善点①: カメラの位置（IPD）を更新する。輻輳（寄り目）はさせず常に平行に保つ。
    func updateCameraPositions() {
        let halfIPD = ipd / 2.0
        leftCameraNode?.simdPosition = simd_float3(-halfIPD, 0, 0)
        rightCameraNode?.simdPosition = simd_float3(halfIPD, 0, 0)
        leftCameraNode?.simdEulerAngles = .zero
        rightCameraNode?.simdEulerAngles = .zero
    }

    // 改善点②: 重力軸を維持するため、QuaternionからYaw(Y軸回転)のみを抽出する関数
    private func getYawRotation(from q: simd_quatf) -> simd_quatf {
        // Zマイナス方向のベクトルを回転させ、XZ平面での角度を計算
        let forward = q.act(simd_float3(0, 0, -1))
        let yaw = atan2(forward.x, -forward.z)
        return simd_quatf(angle: yaw, axis: simd_float3(0, 1, 0))
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let head = headNode,
              let _ = leftCameraNode,
              let _ = rightCameraNode else { return }

        // 頭の姿勢更新
        lock.lock()
        let targetQ = latestQ
        let targetP = latestP
        let doReset = shouldReset
        shouldReset = false
        lock.unlock()
        
        if doReset {
            // 改善点②: PitchやRollまでリセットすると歩行時に斜めに進んでしまうため、Yawのみをリセットする
            let yawQ = getYawRotation(from: targetQ)
            referenceQ = yawQ.inverse
            referenceP = targetP
            smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            smoothP = .zero
        }

        let relativeQ = referenceQ.map { $0 * targetQ } ?? targetQ
        
        // 改善点⑤: 現実の移動距離とスケールが合わない場合の補正
        let scaledTargetP = targetP * positionScale
        let scaledReferenceP = referenceP * positionScale
        let relativeP = referenceQ.map { $0.act(scaledTargetP - scaledReferenceP) } ?? scaledTargetP

        smoothQ = simd_slerp(smoothQ, relativeQ, ALPHA)
        smoothP = smoothP + (relativeP - smoothP) * ALPHA

        head.simdOrientation = smoothQ
        head.simdPosition = smoothP

        // ハンドトラッキングの更新
        updateHandTracking(fov: Float(fieldOfView), scene: renderer.scene)

        DispatchQueue.main.async {
            self.debugPosition = self.smoothP
        }
    }
    
    private func updateHandTracking(fov: Float, scene: SCNScene?) {
        guard let hands = cameraManager?.hands else { return }
        
        hideAllHandNodes()
        setupLaserNodesIfNeeded()
        leftLaserNode?.isHidden = true
        rightLaserNode?.isHidden = true
        
        var hitNodes: Set<SCNNode> = []
        
        for hand in hands {
            let zDist: Float = handBaseZ - (Float(hand.distance) * handDepthMultiplier)
            
            let fovRad = fov * .pi / 180.0
            let aspect: Float = 16.0 / 9.0
            let halfHeight = abs(zDist) * tan(fovRad / 2.0)
            let halfWidth = halfHeight * aspect
            
            var currentJointNodes = hand.isRight ? rightJointNodes : leftJointNodes
            var currentBoneNodes = hand.isRight ? rightBoneNodes : leftBoneNodes
            let color = hand.isRight ? SystemColor.orange : SystemColor.cyan
            
            var joint3DPositions: [VNHumanHandPoseObservation.JointName: simd_float3] = [:]
            
            // 1. ジョイント配置
            for (jointName, point) in hand.joints {
                let adjustedX = (Float(point.x) - 0.5) * handScaleX + handOffsetX
                let adjustedY = (Float(point.y) - 0.5) * handScaleY + handOffsetY
                
                let localX = adjustedX * 2.0 * halfWidth
                let localY = -adjustedY * 2.0 * halfHeight
                let pos3D = simd_float3(localX, localY, zDist)
                joint3DPositions[jointName] = pos3D
                
                if let node = currentJointNodes[jointName] {
                    node.simdPosition = pos3D
                    node.isHidden = false
                    if let sphere = node.geometry as? SCNSphere { sphere.radius = jointRadius }
                } else {
                    let node = createJointNode(color: color)
                    node.simdPosition = pos3D
                    headNode?.addChildNode(node)
                    currentJointNodes[jointName] = node
                }
            }
            
            // 2. ボーン描画
            var boneIndex = 0
            for finger in fingers {
                for i in 0..<(finger.count - 1) {
                    let startJoint = finger[i]
                    let endJoint = finger[i+1]
                    
                    if let startPos = joint3DPositions[startJoint], let endPos = joint3DPositions[endJoint] {
                        if boneIndex < currentBoneNodes.count {
                            let boneNode = currentBoneNodes[boneIndex]
                            updateBoneNode(boneNode, from: startPos, to: endPos, radius: boneRadius)
                            boneNode.isHidden = false
                        } else {
                            let boneNode = createBoneNode(from: startPos, to: endPos, color: color, radius: boneRadius)
                            headNode?.addChildNode(boneNode)
                            currentBoneNodes.append(boneNode)
                        }
                        boneIndex += 1
                    }
                }
            }
            
            if hand.isRight {
                rightJointNodes = currentJointNodes
                rightBoneNodes = currentBoneNodes
            } else {
                leftJointNodes = currentJointNodes
                leftBoneNodes = currentBoneNodes
            }
            
            // 3. ピンチジェスチャー＆レーザービーム判定
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
                
                if let scene = scene, let head = headNode {
                    let worldStart = head.simdWorldTransform * simd_float4(localStart.x, localStart.y, localStart.z, 1.0)
                    let worldEndTarget = head.simdWorldTransform * simd_float4(localEnd.x, localEnd.y, localEnd.z, 1.0)
                    
                    let hits = scene.rootNode.hitTestWithSegment(
                        from: SCNVector3(worldStart.x, worldStart.y, worldStart.z),
                        to: SCNVector3(worldEndTarget.x, worldEndTarget.y, worldEndTarget.z),
                        options: [SCNHitTestOption.firstFoundOnly.rawValue: true, SCNHitTestOption.ignoreHiddenNodes.rawValue: true]
                    )
                    
                    if let firstHit = hits.first {
                        let hitPos = simd_float3(firstHit.worldCoordinates)
                        let dist = simd_distance(simd_float3(worldStart.x, worldStart.y, worldStart.z), hitPos)
                        
                        localEnd = pinchMid + laserDir * dist
                        
                        if targetNodes.contains(firstHit.node) {
                            hitNodes.insert(firstHit.node)
                        }
                    }
                }
                
                let laserNode = hand.isRight ? rightLaserNode : leftLaserNode
                laserNode?.isHidden = false
                updateBoneNode(laserNode!, from: localStart, to: localEnd, radius: 0.002)
            }
            
            // 4. 直接触った場合の当たり判定
            if let indexTipPos = joint3DPositions[.indexTip] {
                let worldPos = headNode!.simdWorldTransform * simd_float4(indexTipPos.x, indexTipPos.y, indexTipPos.z, 1.0)
                let cursorPos = simd_float3(worldPos.x, worldPos.y, worldPos.z)
                
                for node in targetNodes {
                    if simd_distance(cursorPos, node.simdWorldPosition) < 0.08 {
                        hitNodes.insert(node)
                    }
                }
            }
        }
        
        // 色の更新
        for node in targetNodes {
            if hitNodes.contains(node) {
                node.geometry?.firstMaterial?.diffuse.contents = SystemColor.systemGreen
                node.geometry?.firstMaterial?.emission.contents = SystemColor.systemGreen
                node.geometry?.firstMaterial?.emission.intensity = 1.0
            } else {
                node.geometry?.firstMaterial?.diffuse.contents = SystemColor.systemRed
                node.geometry?.firstMaterial?.emission.contents = SystemColor.black
                node.geometry?.firstMaterial?.emission.intensity = 0.0
            }
        }
    }
    
    // MARK: - SceneKit Node Helpers
    private func hideAllHandNodes() {
        leftJointNodes.values.forEach { $0.isHidden = true }
        rightJointNodes.values.forEach { $0.isHidden = true }
        leftBoneNodes.forEach { $0.isHidden = true }
        rightBoneNodes.forEach { $0.isHidden = true }
    }
    
    private func setupLaserNodesIfNeeded() {
        if leftLaserNode == nil {
            leftLaserNode = createLaserNode()
            headNode?.addChildNode(leftLaserNode!)
        }
        if rightLaserNode == nil {
            rightLaserNode = createLaserNode()
            headNode?.addChildNode(rightLaserNode!)
        }
    }
    
    private func createLaserNode() -> SCNNode {
        let cylinder = SCNCylinder(radius: 0.002, height: 1.0)
        let mat = SCNMaterial()
        mat.diffuse.contents = SystemColor.cyan
        mat.emission.contents = SystemColor.cyan
        mat.emission.intensity = 1.0
        cylinder.materials = [mat]
        let node = SCNNode(geometry: cylinder)
        let wrapper = SCNNode()
        wrapper.addChildNode(node)
        return wrapper
    }
    
    private func createJointNode(color: SystemColor) -> SCNNode {
        let sphere = SCNSphere(radius: jointRadius)
        let mat = SCNMaterial()
        mat.diffuse.contents = SystemColor.white
        mat.emission.contents = color
        mat.emission.intensity = 0.8
        sphere.materials = [mat]
        return SCNNode(geometry: sphere)
    }
    
    private func createBoneNode(from: simd_float3, to: simd_float3, color: SystemColor, radius: CGFloat) -> SCNNode {
        let height = CGFloat(simd_distance(from, to))
        let cylinder = SCNCylinder(radius: radius, height: height)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color
        mat.emission.intensity = 0.5
        cylinder.materials = [mat]
        
        let node = SCNNode(geometry: cylinder)
        let wrapper = SCNNode()
        wrapper.addChildNode(node)
        updateBoneNode(wrapper, from: from, to: to, radius: radius)
        return wrapper
    }
    
    private func updateBoneNode(_ wrapper: SCNNode, from: simd_float3, to: simd_float3, radius: CGFloat) {
        let height = simd_distance(from, to)
        if let child = wrapper.childNodes.first, let cylinder = child.geometry as? SCNCylinder {
            cylinder.height = CGFloat(height)
            cylinder.radius = radius
        }
        
        wrapper.simdPosition = (from + to) / 2.0
        
        let yAxis = simd_float3(0, 1, 0)
        let direction = normalize(to - from)
        let dot = simd_dot(yAxis, direction)
        
        if abs(dot) < 0.9999 {
            let axis = normalize(simd_cross(yAxis, direction))
            let angle = acos(dot)
            wrapper.simdOrientation = simd_quatf(angle: angle, axis: axis)
        } else if dot < 0 {
            wrapper.simdOrientation = simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        } else {
            wrapper.simdOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
    }
}

// MARK: - AR Mode View
struct ARModeView: View {
    @Binding var currentMode: AppState

    @State private var scene = SCNScene()
    @State private var headNode = SCNNode()
    @State private var leftCameraNode = SCNNode()
    @State private var rightCameraNode = SCNNode()
    
    @StateObject private var arDelegate = ARSceneDelegate()
    @StateObject private var cameraManager = CameraManager()
    
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            HStack(spacing: 0) {
                RawSceneView(scene: scene, cameraNode: leftCameraNode, delegate: arDelegate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                RawSceneView(scene: scene, cameraNode: rightCameraNode, delegate: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .edgesIgnoringSafeArea(.all)

            if showSettings {
                settingsPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            VStack {
                Spacer()
                HStack {
                    Button(action: {
                        withAnimation(.spring()) { showSettings.toggle() }
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding()
                    Spacer()
                }
            }
        }
        .onAppear {
            setupScene()
            arDelegate.headNode = headNode
            arDelegate.leftCameraNode = leftCameraNode
            arDelegate.rightCameraNode = rightCameraNode
            arDelegate.cameraManager = cameraManager
            
            // 初期のIPDオフセットを適用
            arDelegate.updateCameraPositions()
            
            startIMU()
            cameraManager.checkPermissions()
        }
        .onDisappear {
            cameraManager.session.stopRunning()
        }
    }

    // MARK: - Settings Panel UI
    private var settingsPanel: some View {
        HStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("AR + Hand Tracking Settings")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    Text(String(format: "Pos: X:%.2f Y:%.2f Z:%.2f",
                                arDelegate.debugPosition.x, arDelegate.debugPosition.y, arDelegate.debugPosition.z))
                        .font(.system(.caption, design: .monospaced))
                    
                    Button(action: { arDelegate.recenter() }) {
                        Text("Recenter (正面リセット)")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(8)
                    }.buttonStyle(PlainButtonStyle())
                    
                    Divider().background(Color.gray)
                    
                    Group {
                        Text("Glasses Display").font(.subheadline).foregroundColor(.yellow)
                        sliderRow(title: "IPD", value: $arDelegate.ipd, range: 0.000...0.075, format: "%.3f m")
                        sliderRow(title: "FOV (Horizontal)", value: $arDelegate.fieldOfView, range: 20.0...80.0, format: "%.1f°")
                        sliderRow(title: "Pos Scale", value: $arDelegate.positionScale, range: 0.1...10.0, format: "%.2f")
                    }
                    
                    Divider().background(Color.gray)
                    
                    Group {
                        Text("Hand Transform").font(.subheadline).foregroundColor(.yellow)
                        sliderRow(title: "Scale X", value: $arDelegate.handScaleX, range: 0.1...3.0, format: "%.2f")
                        sliderRow(title: "Scale Y", value: $arDelegate.handScaleY, range: 0.1...3.0, format: "%.2f")
                        sliderRow(title: "Offset X", value: $arDelegate.handOffsetX, range: -1.0...1.0, format: "%.2f")
                        sliderRow(title: "Offset Y", value: $arDelegate.handOffsetY, range: -1.0...1.0, format: "%.2f")
                    }
                    
                    Divider().background(Color.gray)
                    
                    Group {
                        Text("Hand Depth & Size").font(.subheadline).foregroundColor(.yellow)
                        sliderRow(title: "Base Z Dist", value: $arDelegate.handBaseZ, range: -1.0...0.0, format: "%.2f m")
                        sliderRow(title: "Depth Multiplier", value: $arDelegate.handDepthMultiplier, range: 0.0...0.1, format: "%.3f")
                        sliderRow(title: "Joint Size", value: $arDelegate.jointRadius, range: 0.001...0.02, format: "%.3f")
                        sliderRow(title: "Bone Thickness", value: $arDelegate.boneRadius, range: 0.001...0.02, format: "%.3f")
                    }
                }
                .padding()
            }
            .frame(width: 300)
            .background(Color.black.opacity(0.85))
            .cornerRadius(12)
            .foregroundColor(.white)
            .padding(.leading, 16)
            .padding(.vertical, 40)
            
            Spacer()
        }
    }
    
    private func sliderRow<V: BinaryFloatingPoint>(title: String, value: Binding<V>, range: ClosedRange<V>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, Double(value.wrappedValue))).font(.caption)
            }
            Slider(value: Binding<Double>(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = V($0) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }

    private func startIMU() {
        let mgr = GlassesManager.shared()
        _ = mgr.setupAndConnect()
        mgr.startPosePolling { x, y, z, qw, qx, qy, qz in
            self.arDelegate.updatePose(x: x, y: y, z: z, qw: qw, qx: qx, qy: qy, qz: qz)
        }
    }

    private func setupScene() {
        headNode.simdPosition = .zero
        scene.rootNode.addChildNode(headNode)

        let leftCam = SCNCamera()
        leftCam.zNear = 0.05
        leftCam.zFar = 50.0
        leftCam.projectionDirection = .horizontal
        leftCam.fieldOfView = arDelegate.fieldOfView
        leftCameraNode.camera = leftCam
        headNode.addChildNode(leftCameraNode)

        let rightCam = SCNCamera()
        rightCam.zNear = 0.05
        rightCam.zFar = 50.0
        rightCam.projectionDirection = .horizontal
        rightCam.fieldOfView = arDelegate.fieldOfView
        rightCameraNode.camera = rightCam
        headNode.addChildNode(rightCameraNode)

        scene.background.contents = NSColor.black

        let shapesData: [(pos: simd_float3, geometry: SCNGeometry, color: SystemColor)] = [
            // 箱
            (simd_float3(-0.6, 0.0, -2.0), SCNBox(width: 0.3, height: 0.3, length: 0.3, chamferRadius: 0.01), .systemRed),
            // 球体
            (simd_float3( 0.0, 0.0, -2.0), SCNSphere(radius: 0.2), .systemBlue),
            // 円柱
            (simd_float3( 0.6, 0.0, -2.0), SCNCylinder(radius: 0.15, height: 0.4), .systemGreen)
        ]

        for item in shapesData {
            let mat = SCNMaterial()
            mat.diffuse.contents = item.color
            item.geometry.materials = [mat]
            
            let node = SCNNode(geometry: item.geometry)
            node.simdPosition = item.pos
            scene.rootNode.addChildNode(node)
            
            arDelegate.targetNodes.append(node)
        }
        
        // 照明
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 500
        let ambNode = SCNNode()
        ambNode.light = ambient
        scene.rootNode.addChildNode(ambNode)

        let dir = SCNLight()
        dir.type = .directional
        dir.intensity = 800
        let dirNode = SCNNode()
        dirNode.light = dir
        dirNode.simdEulerAngles = simd_float3(-0.6, 0.6, 0)
        scene.rootNode.addChildNode(dirNode)
    }
}
