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
    let delegate:   SCNSceneRendererDelegate

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
    var cameraNode: SCNNode?

    private let lock = NSLock()
    
    // センサーからの最新の生データ
    private var latestQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var latestP = simd_float3(0, 0, 0)

    // スムージング用
    private var smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothP = simd_float3(0, 0, 0)

    // リセット（正面固定）の基準点
    private var referenceQ: simd_quatf?
    private var referenceP: simd_float3 = .zero
    private var shouldReset = true

    // 追従速度 (1.0で遅延なし。少し滑らかにしたい場合は0.8程度に)
    private let ALPHA: Float = 0.9

    // ── デバッグ用プロパティ ──
    @Published var debugEulerDegrees: simd_float3 = .zero
    @Published var debugPosition: simd_float3 = .zero
    
    override init() {
        super.init()
    }

    func recenter() {
        lock.lock()
        shouldReset = true
        lock.unlock()
    }

    // 引数の順序を Objective-C 側 (x, y, z, qw, qx, qy, qz) と完全に一致させました
    func updatePose(x: Float, y: Float, z: Float, qw: Float, qx: Float, qy: Float, qz: Float) {
        // GL Pose (右手座標系) をそのまま SceneKit (右手座標系) にマッピング
        let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
        let p = simd_float3(x, y, z)

        lock.lock()
        latestQ = q
        latestP = p
        lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let cam = cameraNode else { return }

        lock.lock()
        let targetQ = latestQ
        let targetP = latestP
        let doReset = shouldReset
        shouldReset = false
        lock.unlock()
        
        // ── 正面リセットの処理 ──
        if doReset {
            referenceQ = targetQ.inverse // 現在の姿勢を打ち消す逆回転
            referenceP = targetP         // 現在の位置を原点とする
            smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            smoothP = .zero
        }

        let relativeQ: simd_quatf
        let relativeP: simd_float3
        
        if let refQ = referenceQ {
            // 回転：初期姿勢を基準にした相対回転
            relativeQ = refQ * targetQ
            
            // 位置：現実世界での移動差分を、向いている方向（初期姿勢）に合わせて回転させる
            let rawDeltaP = targetP - referenceP
            relativeP = refQ.act(rawDeltaP)
        } else {
            relativeQ = targetQ
            relativeP = targetP
        }

        // SLERPとLERPによるスムージング
        smoothQ = simd_slerp(smoothQ, relativeQ, ALPHA)
        smoothP = smoothP + (relativeP - smoothP) * ALPHA

        // ── 空間固定の鉄則：加工せず1:1で適用する ──
        cam.simdOrientation = smoothQ
        cam.simdPosition = smoothP

        // UI用に値を送る
        let finalEuler = cam.simdEulerAngles
        DispatchQueue.main.async {
            self.debugEulerDegrees = simd_float3(
                finalEuler.x * 180 / .pi,
                finalEuler.y * 180 / .pi,
                finalEuler.z * 180 / .pi
            )
            self.debugPosition = self.smoothP
        }
    }
}

// MARK: - AR Mode View
struct ARModeView: View {
    @Binding var currentMode: AppState

    @State private var scene      = SCNScene()
    @State private var cameraNode = SCNNode()
    @StateObject private var arDelegate = ARSceneDelegate()

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            RawSceneView(
                scene:      scene,
                cameraNode: cameraNode,
                delegate:   arDelegate
            )
            .edgesIgnoringSafeArea(.all)

            // ── デバッグ＆コントロール UI ──
            VStack(alignment: .leading, spacing: 12) {
                Text("AR Tracking: 6DoF")
                    .font(.headline)
                    .foregroundColor(.green)
                
                // カメラのオイラー角 (度数法)
                Text(String(format: "Rot: P:%.1f°  Y:%.1f°  R:%.1f°",
                            arDelegate.debugEulerDegrees.x, arDelegate.debugEulerDegrees.y, arDelegate.debugEulerDegrees.z))
                    .font(.system(.caption, design: .monospaced))
                
                // カメラの位置 (メートル)
                Text(String(format: "Pos: X:%.2f  Y:%.2f  Z:%.2f",
                            arDelegate.debugPosition.x, arDelegate.debugPosition.y, arDelegate.debugPosition.z))
                    .font(.system(.caption, design: .monospaced))
                
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
            .position(x: 160, y: 150) // 画面左上に配置

            // 元の戻るボタン (App state management assumed)
            /* VStack {
                Spacer()
                BackButton(currentMode: $currentMode)
                    .padding()
            }
            */
        }
        .onAppear {
            setupScene()
            arDelegate.cameraNode = cameraNode
            startIMU()

            DispatchQueue.main.async {
                NSApp.windows.forEach {
                    $0.backgroundColor = .black
                    $0.isOpaque        = true
                }
            }
        }
    }

    // MARK: - IMU 開始
    private func startIMU() {
        let mgr = GlassesManager.shared()
        _ = mgr.setupAndConnect()
        
        // ★修正点：引数の受け取り順序をObj-C側に合わせました
        mgr.startPosePolling { x, y, z, qw, qx, qy, qz in
            self.arDelegate.updatePose(x: x, y: y, z: z, qw: qw, qx: qx, qy: qy, qz: qz)
        }
    }

    // MARK: - シーン構築
    private func setupScene() {
        // ── カメラ ──────────────────────────────────────────────────
        let cam         = SCNCamera()
        cam.zNear       = 0.05
        cam.zFar        = 50.0
        // グラスの物理的な視野角(FOV)に合わせます。
        // ※もし空間固定時に「首を振ると箱が少し滑る」と感じる場合は、ここの数値を 30.0 ~ 45.0 の間で調整してください。
        cam.fieldOfView = 35.0
        cameraNode.camera       = cam
        cameraNode.simdPosition = .zero
        scene.rootNode.addChildNode(cameraNode)

        scene.background.contents = NSColor.black

        // ── 立方体 ───────────────────────────────────────────────────
        let box = SCNBox(width: 0.4, height: 0.4, length: 0.4, chamferRadius: 0.02)
        box.materials = [
            makeMat(.systemBlue),   // 前面
            makeMat(.systemRed),    // 背面
            makeMat(.systemGreen),  // 上面
            makeMat(.systemOrange), // 下面
            makeMat(.systemYellow), // 左面
            makeMat(.systemPurple), // 右面
        ]
        let boxNode = SCNNode(geometry: box)
        boxNode.simdPosition = simd_float3(0, 0, -2.0)
        scene.rootNode.addChildNode(boxNode)

        // ── 照明 ──────────────────────────────────────────────────
        let ambient       = SCNLight()
        ambient.type      = .ambient
        ambient.intensity = 500
        let ambNode       = SCNNode()
        ambNode.light     = ambient
        scene.rootNode.addChildNode(ambNode)

        let dir           = SCNLight()
        dir.type          = .directional
        dir.intensity     = 800
        let dirNode       = SCNNode()
        dirNode.light     = dir
        dirNode.simdEulerAngles = simd_float3(-0.6, 0.6, 0)
        scene.rootNode.addChildNode(dirNode)
    }

    private func makeMat(_ color: SystemColor) -> SCNMaterial {
        let m               = SCNMaterial()
        m.diffuse.contents  = color
        m.specular.contents = SystemColor.white
        m.shininess         = 60
        m.lightingModel     = .phong
        return m
    }
}
