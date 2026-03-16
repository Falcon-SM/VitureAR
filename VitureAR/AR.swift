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
//
// ■ 空間固定の仕組み
//   SceneKit のカメラは「世界座標の中でどこを向いているか」で決まる。
//   IMU の姿勢クォータニオンをそのままカメラの orientation に入れると、
//   頭が右を向いた → カメラが右を向く → 立方体はカメラの左に見える
//   → 「立方体は世界に固定されたまま、自分が動いた」感覚になる。
//
// ■ 位置(x,y,z)は使わない理由
//   VITURE のIMUのみデバイスでは位置は加速度の二重積分であり、
//   数秒でドリフトして制御不能になる。
//   純粋な「回転のみ(3DoF)」で確実に空間固定する。
//
// ■ SLERP alpha について
//   alpha を高く(0.9)することで遅延を最小化する。
//   低すぎると「カメラが追いかけてくる」感覚になり空間固定に見えない。
class ARSceneDelegate: NSObject, SCNSceneRendererDelegate {
    var cameraNode: SCNNode?

    private let lock     = NSLock()
    private var latestQ  = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var smoothQ  = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // 高い alpha = 低遅延 = 空間固定が自然に感じる
    // 0.9 → 残留誤差が 1/10 になるまで約 2 フレーム (~33ms)
    private let ALPHA: Float = 0.9

    // ── 座標系補正 ───────────────────────────────────────────────────
    // VITURE SDK の "gl_pose" は OpenGL 規約:
    //   X: 右, Y: 上, Z: 手前 (右手系)
    // SceneKit も同じ右手系 Y-up なので追加変換は不要なはず。
    // もし左右・上下・前後が逆に見える場合は下の定数を変えてデバッグ:
    //   FLIP_X: 左右反転  FLIP_Y: 上下反転  FLIP_Z: 前後反転
    private let FLIP_X = false
    private let FLIP_Y = false
    private let FLIP_Z = false

    func updatePose(qx: Float, qy: Float, qz: Float, qw: Float,
                    x _x: Float, y _y: Float, z _z: Float) {
        var q = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)

        // 軸反転が必要な場合はコンポーネントの符号を反転
        if FLIP_X { q = simd_quatf(ix: -q.imag.x, iy: q.imag.y, iz: q.imag.z, r: q.real) }
        if FLIP_Y { q = simd_quatf(ix: q.imag.x, iy: -q.imag.y, iz: q.imag.z, r: q.real) }
        if FLIP_Z { q = simd_quatf(ix: q.imag.x, iy: q.imag.y, iz: -q.imag.z, r: q.real) }

        lock.lock()
        latestQ = q
        lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let cam = cameraNode else { return }

        lock.lock()
        let target = latestQ
        lock.unlock()

        // SLERP: 前フレームから target へ高速追従
        smoothQ = simd_slerp(smoothQ, target, ALPHA)

        // ── カメラを回転させる (位置は原点固定) ──
        // これだけで3DoF空間固定が成立する
        cam.simdOrientation = smoothQ
        cam.simdPosition    = .zero
    }
}

// MARK: - AR Mode View
struct ARModeView: View {
    @Binding var currentMode: AppState

    @State private var scene      = SCNScene()
    @State private var cameraNode = SCNNode()
    @State private var arDelegate = ARSceneDelegate()

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            RawSceneView(
                scene:      scene,
                cameraNode: cameraNode,
                delegate:   arDelegate
            )
            .edgesIgnoringSafeArea(.all)

            BackButton(currentMode: $currentMode)
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
        // 対角 FOV 52° / 16:9 → 垂直 FOV ≈ 27°
        cam.fieldOfView = 27.0
        cameraNode.camera       = cam
        cameraNode.simdPosition = .zero
        scene.rootNode.addChildNode(cameraNode)

        scene.background.contents = NSColor.black

        // ── 立方体 ───────────────────────────────────────────────────
        // カメラ正面 2m に 0.4m の立方体
        // 6面別々の色 → 回り込んで別の面が見えたら空間固定成功の証拠
        let box = SCNBox(width: 0.4, height: 0.4, length: 0.4, chamferRadius: 0.02)
        box.materials = [
            makeMat(.systemBlue),   // 前面 (正面から見える)
            makeMat(.systemRed),    // 背面 (後ろに回ると見える)
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
