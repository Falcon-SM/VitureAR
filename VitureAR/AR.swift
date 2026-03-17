#if os(macOS)
import AppKit
typealias SystemColor = NSColor
#else
import UIKit
typealias SystemColor = UIColor
#endif

import SwiftUI
import SceneKit
import simd
import Combine

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
        v.backgroundColor            = .black
        v.wantsLayer                 = true
        v.layer?.isOpaque            = true
        v.layer?.backgroundColor     = CGColor(gray: 0, alpha: 1)
        return v
    }
    func updateNSView(_ nsView: SCNView, context: Context) {}
}

// MARK: - AR Scene Delegate
class ARSceneDelegate: NSObject, SCNSceneRendererDelegate, ObservableObject {
    var headNode: SCNNode?
    var leftCameraNode: SCNNode?
    var rightCameraNode: SCNNode?

    private let lock = NSLock()
    private var latestQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var latestP = simd_float3(0, 0, 0)
    private var smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothP = simd_float3(0, 0, 0)
    private var referenceQ: simd_quatf?
    private var referenceP: simd_float3 = .zero
    private var shouldReset = true
    private let ALPHA: Float = 0.9

    // ── パラメータ群 ──
    @Published var ipd: Float = 0.063 // 瞳孔間距離(63mm)
    @Published var fieldOfView: CGFloat = 35.0 {
        didSet {
            leftCameraNode?.camera?.fieldOfView = fieldOfView
            rightCameraNode?.camera?.fieldOfView = fieldOfView
        }
    }
    
    // ── デバッグ＆UI用情報 ──
    @Published var debugPosition: simd_float3 = .zero
    @Published var detectedDistance: Float = 10.0 // 検出した物体までの距離
    
    // 内部でのピント距離（滑らかに追従させるため）
    private var smoothConvergenceDist: Float = 10.0

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

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let head = headNode,
              let leftCam = leftCameraNode,
              let rightCam = rightCameraNode,
              let scene = renderer.scene else { return }

        // ── 1. 姿勢・位置の取得と適用 ──
        lock.lock()
        let targetQ = latestQ
        let targetP = latestP
        let doReset = shouldReset
        shouldReset = false
        lock.unlock()
        
        if doReset {
            referenceQ = targetQ.inverse
            referenceP = targetP
            smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            smoothP = .zero
        }

        let relativeQ = referenceQ.map { $0 * targetQ } ?? targetQ
        let relativeP = referenceQ.map { $0.act(targetP - referenceP) } ?? targetP

        smoothQ = simd_slerp(smoothQ, relativeQ, ALPHA)
        smoothP = smoothP + (relativeP - smoothP) * ALPHA

        head.simdOrientation = smoothQ
        head.simdPosition = smoothP

        // ── 2. 正面の物体までの距離（Raycast）を測る ──
        let headWorldPos = head.simdWorldPosition
        // 頭の正面ベクトルを計算 (ローカルの Z- マイナス方向が正面)
        let localForward = simd_float4(0, 0, -1, 0)
        let worldForwardVec = head.simdWorldTransform * localForward
        let headForward = normalize(simd_float3(worldForwardVec.x, worldForwardVec.y, worldForwardVec.z))
        
        // 最大50m先までHitTest
        let maxDist: Float = 50.0
        let endPos = headWorldPos + headForward * maxDist

        let hits = scene.rootNode.hitTestWithSegment(
            from: SCNVector3(headWorldPos),
            to: SCNVector3(endPos),
            options: [
                SCNHitTestOption.ignoreHiddenNodes.rawValue: true,
                SCNHitTestOption.firstFoundOnly.rawValue: true
            ]
        )

        // ヒットしたら距離を算出、なければデフォルト(10m先)とする
        var targetDist: Float = 10.0
        if let firstHit = hits.first {
            let hitPos = simd_float3(firstHit.worldCoordinates)
            targetDist = simd_distance(headWorldPos, hitPos)
            // 極端に近すぎる場合（0.15m以下）はクリッピング
            targetDist = max(0.15, targetDist)
        }

        // 距離を滑らかに補間する（0.1の係数でフワッと追従させる）
        smoothConvergenceDist = smoothConvergenceDist + (targetDist - smoothConvergenceDist) * 0.1

        // ── 3. 自動輻輳（オート寄り目）と配置 ──
        let halfIPD = self.ipd / 2.0
        
        // 位置を左右にズラす
        leftCam.simdPosition = simd_float3(-halfIPD, 0, 0)
        rightCam.simdPosition = simd_float3(halfIPD, 0, 0)
        
        // 三角関数（atan2）を用いて、目標距離に向けてカメラを内側に回転（Toe-in）させる
        let angle = atan2(halfIPD, smoothConvergenceDist)
        
        // 左カメラは右回転(+Y)、右カメラは左回転(-Y)
        leftCam.simdEulerAngles = simd_float3(0, angle, 0)
        rightCam.simdEulerAngles = simd_float3(0, -angle, 0)

        // ── 4. UI更新用に値を送る ──
        let finalDist = smoothConvergenceDist
        DispatchQueue.main.async {
            self.debugPosition = self.smoothP
            self.detectedDistance = finalDist
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

            // ── デバッグ＆コントロール UI ──
            VStack(alignment: .leading, spacing: 12) {
                Text("AR Auto-Focus 3D")
                    .font(.headline)
                    .foregroundColor(.green)
                
                // 検出された物体までの距離
                HStack {
                    Text("Focus:")
                        .font(.caption)
                    Text(String(format: "%.2f m", arDelegate.detectedDistance))
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(arDelegate.detectedDistance < 9.9 ? .orange : .white)
                }
                
                // 視差 (IPD) 調整スライダー
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "基本視差 (IPD): %.1f mm", arDelegate.ipd * 1000.0))
                        .font(.caption)
                    Slider(value: $arDelegate.ipd, in: 0.0...0.100, step: 0.001)
                }

                // 視野角 (FOV) 調整スライダー
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "視野角 (FOV): %.1f°", arDelegate.fieldOfView))
                        .font(.caption)
                    Slider(value: $arDelegate.fieldOfView, in: 20.0...60.0, step: 1.0)
                }
                
                Button(action: {
                    arDelegate.recenter()
                }) {
                    Text("Recenter (正面リセット)")
                        .font(.system(size: 14, weight: .bold))
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.8))
                        .cornerRadius(8)
                }
                .padding(.top, 4)
            }
            .foregroundColor(.white)
            .padding()
            .frame(width: 260)
            .background(Color.black.opacity(0.7))
            .cornerRadius(12)
            .position(x: 160, y: 180)
        }
        .onAppear {
            setupScene()
            arDelegate.headNode = headNode
            arDelegate.leftCameraNode = leftCameraNode
            arDelegate.rightCameraNode = rightCameraNode
            startIMU()
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
        // カメラ群
        headNode.simdPosition = .zero
        scene.rootNode.addChildNode(headNode)

        let leftCam = SCNCamera()
        leftCam.zNear = 0.05
        leftCam.zFar = 50.0
        leftCam.fieldOfView = arDelegate.fieldOfView
        leftCameraNode.camera = leftCam
        headNode.addChildNode(leftCameraNode)

        let rightCam = SCNCamera()
        rightCam.zNear = 0.05
        rightCam.zFar = 50.0
        rightCam.fieldOfView = arDelegate.fieldOfView
        rightCameraNode.camera = rightCam
        headNode.addChildNode(rightCameraNode)

        scene.background.contents = NSColor.black

        // ── テスト用のオブジェクト群 ──
        // 近く(1m先)にある小さな箱
        let frontBox = SCNBox(width: 0.2, height: 0.2, length: 0.2, chamferRadius: 0.02)
        frontBox.firstMaterial?.diffuse.contents = SystemColor.systemRed
        let frontNode = SCNNode(geometry: frontBox)
        frontNode.simdPosition = simd_float3(0.3, -0.2, -1.0)
        scene.rootNode.addChildNode(frontNode)

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
