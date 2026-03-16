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

    private let lock     = NSLock()
    private var latestQ  = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothQ  = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    private var referenceQ: simd_quatf?
    private var shouldReset = true

    private let ALPHA: Float = 0.9

    // ── デバッグ＆調整用プロパティ (UIでリアルタイム変更可能) ──
    @Published var debugRawQ: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    @Published var debugEulerDegrees: simd_float3 = .zero
    
    // 空間固定の「激しさ」を調整する倍率（1.0〜3.0などを想定）
    @Published var rotationMultiplier: Float = 1.5
    // 近づいた時などに画面が斜めに回ってしまうのを防ぐ（Z軸回転のロック）
    @Published var lockRoll: Bool = true
    // 微積分の代わりに人体構造を用いた疑似位置推定（首の付け根を支点にする）
    @Published var useNeckModel: Bool = true

    override init() {
        super.init()
    }

    func recenter() {
        lock.lock()
        shouldReset = true
        lock.unlock()
    }

    func updatePose(qx: Float, qy: Float, qz: Float, qw: Float,
                    x _x: Float, y _y: Float, z _z: Float) {
        
        // 座標系の90度回転および反転補正
        let q = simd_quatf(ix: qy, iy: -qx, iz: -qz, r: qw)

        lock.lock()
        latestQ = q
        lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let cam = cameraNode else { return }

        lock.lock()
        let target = latestQ
        let doReset = shouldReset
        let currentMult = rotationMultiplier
        let doLockRoll = lockRoll
        let doNeckModel = useNeckModel
        shouldReset = false
        lock.unlock()

        // ── 正面リセットの処理 ──
        if doReset {
            referenceQ = target.inverse
            smoothQ = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }

        let relativeQ: simd_quatf
        if let refQ = referenceQ {
            relativeQ = refQ * target
        } else {
            relativeQ = target
        }

        // SLERP: 前フレームから target へ高速追従
        smoothQ = simd_slerp(smoothQ, relativeQ, ALPHA)

        // ── 回転倍率とロール（斜め傾き）ロックの適用 ──
        cam.simdOrientation = smoothQ
        var euler = cam.simdEulerAngles
        
        // 「もっと激しく動かしたい」に対応するための倍率処理
        euler.x *= currentMult // 上下（Pitch）の動きを強調
        euler.y *= currentMult // 左右（Yaw）の動きを強調
        
        // 近づいた際に視界が回転してしまうのを防止
        if doLockRoll {
            euler.z = 0
        }
        
        cam.simdEulerAngles = euler

        // ── 疑似位置推定 (Neck Model / 人体構造アプローチ) ──
        // 加速度の2重積分はドリフトですぐに破綻するため、首を支点とした運動学モデルで位置を補完します。
        // これにより、右を向いた時に単にカメラが回るだけでなく「右後方に移動」するため、空間固定感が強まります。
        if doNeckModel {
            // 首の付け根の位置（目から見て下15cm、後ろ10cmあたりを想定）
            let neckOffset = simd_float3(0, -0.15, -0.10)
            
            // 現在のカメラの回転行列を使って、首中心からの眼球の位置を再計算
            let rotMatrix = simd_matrix3x3(cam.simdOrientation)
            let rotatedEyePos = rotMatrix * (-neckOffset)
            
            // カメラの位置を更新
            cam.simdPosition = neckOffset + rotatedEyePos
        } else {
            cam.simdPosition = .zero
        }

        // UI用に値を送る
        let finalEuler = cam.simdEulerAngles
        DispatchQueue.main.async {
            self.debugRawQ = target
            self.debugEulerDegrees = simd_float3(
                finalEuler.x * 180 / .pi,
                finalEuler.y * 180 / .pi,
                finalEuler.z * 180 / .pi
            )
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
                Text("AR Calibration")
                    .font(.headline)
                    .foregroundColor(.green)
                
                // カメラのオイラー角 (度数法)
                Text(String(format: "Cam: P:%.1f°  Y:%.1f°  R:%.1f°",
                            arDelegate.debugEulerDegrees.x, arDelegate.debugEulerDegrees.y, arDelegate.debugEulerDegrees.z))
                    .font(.system(.caption, design: .monospaced))
                
                // 空間固定の激しさスライダー
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "動きの倍率 (Multiplier): %.1fx", arDelegate.rotationMultiplier))
                        .font(.caption)
                    Slider(value: $arDelegate.rotationMultiplier, in: 1.0...5.0, step: 0.1)
                }
                
                // 機能トグルスイッチ
                Toggle("斜め回転を防止 (Roll Lock)", isOn: $arDelegate.lockRoll)
                    .font(.caption)
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                
                Toggle("首モデル位置推定 (Neck Model)", isOn: $arDelegate.useNeckModel)
                    .font(.caption)
                    .toggleStyle(SwitchToggleStyle(tint: .green))
                
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
            .position(x: 160, y: 180) // 画面左上に配置

            // 元の戻るボタン
            VStack {
                Spacer()
                BackButton(currentMode: $currentMode)
                    .padding()
            }
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
        mgr.startPosePolling { qx, qy, qz, qw, x, y, z in
            self.arDelegate.updatePose(qx: qx, qy: qy, qz: qz, qw: qw,
                                       x: x,  y: y,  z: z)
        }
    }

    // MARK: - シーン構築
    private func setupScene() {
        // ── カメラ ──────────────────────────────────────────────────
        let cam         = SCNCamera()
        cam.zNear       = 0.05
        cam.zFar        = 50.0
        // もしスライダーで倍率を上げても「ズレてる」と感じる場合は、
        // 物理的なグラスの視野角に合わせてこの値を 20〜45 の間で調整してみてください。
        cam.fieldOfView = 30.0
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
