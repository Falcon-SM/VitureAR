import AppKit
internal import AVFoundation
typealias NativeViewRepresentable = NSViewRepresentable
typealias SystemColor = NSColor

import SwiftUI
import RealityKit
import simd

// MARK: - ARView ラッパー
struct RawARView: NativeViewRepresentable {
    let spacialCoordinator: SpacialCoordinator
    let handCoordinator: HandTrackingCoordinator
    let isLeft: Bool

    #if os(macOS)
    func makeNSView(context: Context) -> ARView { makeView() }
    func updateNSView(_ nsView: ARView, context: Context) {}
    #else
    func makeUIView(context: Context) -> ARView { makeView() }
    func updateUIView(_ uiView: ARView, context: Context) {}
    #endif
    
    private func makeView() -> ARView {
        let arView = ARView(frame: .zero)
        arView.environment.background = .color(SystemColor.black)
        
        if isLeft {
            spacialCoordinator.leftView = arView
        } else {
            spacialCoordinator.rightView = arView
        }
        
        DispatchQueue.main.async {
            spacialCoordinator.setup()
            if let lv = spacialCoordinator.leftView, let rv = spacialCoordinator.rightView {
                handCoordinator.setupIfNeeded(leftView: lv, rightView: rv, spacial: spacialCoordinator)
            }
        }
        
        return arView
    }
}

// MARK: - AR Mode View (SwiftUI)
struct ARModeView: View {
    @Binding var currentMode: AppState
    @EnvironmentObject private var calibration: CalibrationViewModel

    @StateObject private var spacialCoordinator = SpacialCoordinator()
    @StateObject private var handCoordinator = HandTrackingCoordinator()
    @StateObject private var cameraManager = CameraManager()
    
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)

            HStack(spacing: 0) {
                RawARView(spacialCoordinator: spacialCoordinator, handCoordinator: handCoordinator, isLeft: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                RawARView(spacialCoordinator: spacialCoordinator, handCoordinator: handCoordinator, isLeft: false)
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
            handCoordinator.cameraManager = cameraManager
            startIMU()
            cameraManager.checkPermissions()
            
            // Sync initial hand transform from shared calibration
            handCoordinator.handScaleX  = Float(calibration.leftParams.scaleX)
            handCoordinator.handScaleY  = Float(calibration.leftParams.scaleY)
            handCoordinator.handOffsetX = Float(calibration.leftParams.offsetX)
            handCoordinator.handOffsetY = Float(calibration.leftParams.offsetY)
        }
        .onChange(of: calibration.leftParams.scaleX)  { _, v in handCoordinator.handScaleX  = Float(v) }
        .onChange(of: calibration.leftParams.scaleY)  { _, v in handCoordinator.handScaleY  = Float(v) }
        .onChange(of: calibration.leftParams.offsetX) { _, v in handCoordinator.handOffsetX = Float(v) }
        .onChange(of: calibration.leftParams.offsetY) { _, v in handCoordinator.handOffsetY = Float(v) }
        .onDisappear {
            cameraManager.session.stopRunning()
        }
    }

    // MARK: - Settings Panel UI
    // ★ 変更: 「Hand Transform」セクションにスライダーを追加
    //   Scale X/Y、Offset X/Y、Wrist Target Length、Depth Compression を直接調整可能に
    private var settingsPanel: some View {
        HStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // ── ヘッダー ──
                    Text("RealityKit + Hand Tracking")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    Text(String(format: "Pos: X:%.2f Y:%.2f Z:%.2f",
                                spacialCoordinator.debugPosition.x,
                                spacialCoordinator.debugPosition.y,
                                spacialCoordinator.debugPosition.z))
                        .font(.system(.caption, design: .monospaced))
                    
                    Button(action: { spacialCoordinator.recenter() }) {
                        Text("Recenter (正面リセット)")
                            .font(.system(size: 14, weight: .bold))
                            .padding(8)
                            .frame(maxWidth: .infinity)
                            .background(Color.blue.opacity(0.8))
                            .cornerRadius(8)
                    }.buttonStyle(PlainButtonStyle())
                    
                    Divider().background(Color.gray)
                    
                    // ── Glasses Display ──
                    Group {
                        Text("Glasses Display").font(.subheadline).foregroundColor(.yellow)
                        sliderRow(title: "IPD",
                                  value: $spacialCoordinator.ipd,
                                  range: 0.000...0.075,
                                  format: "%.3f m")
                        sliderRow(title: "FOV (Horizontal)",
                                  value: $spacialCoordinator.fieldOfView,
                                  range: 20.0...80.0,
                                  format: "%.1f°")
                        sliderRow(title: "Pos Scale",
                                  value: $spacialCoordinator.positionScale,
                                  range: 0.1...10.0,
                                  format: "%.2f")
                    }
                    
                    Divider().background(Color.gray)
                    
                    // ── ★ Hand Transform（直接スライダーに変更）──
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hand Transform").font(.subheadline).foregroundColor(.yellow)
                        
                        // Scale X（Y にも連動）
                        // 手が大きすぎ → 下げる / 小さすぎ → 上げる
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Scale X/Y").font(.caption)
                                Spacer()
                                Text(String(format: "%.2f", handCoordinator.handScaleX)).font(.caption)
                            }
                            Slider(value: Binding<Double>(
                                get: { Double(handCoordinator.handScaleX) },
                                set: {
                                    handCoordinator.handScaleX = Float($0)
                                    handCoordinator.handScaleY = Float($0)
                                }
                            ), in: 0.1...3.0)
                        }
                        
                        // Offset X（左右位置ずれの補正）
                        sliderRow(title: "Offset X",
                                  value: $handCoordinator.handOffsetX,
                                  range: Float(-1000)...Float(1000),
                                  format: "%.0f px")
                        
                        // Offset Y（上下位置ずれの補正）
                        sliderRow(title: "Offset Y",
                                  value: $handCoordinator.handOffsetY,
                                  range: Float(-1000)...Float(1000),
                                  format: "%.0f px")
                    }
                    
                    Divider().background(Color.gray)
                    
                    // ── ★ Hand Depth & Size ──
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Hand Depth & Size").font(.subheadline).foregroundColor(.yellow)
                        
                        // Wrist Target Length: 手首〜中指MCPの実寸基準
                        // ↑ 上げると手が奥に / ↓ 下げると手が手前に
                        sliderRow(title: "Wrist Size (m)",
                                  value: $handCoordinator.wristTargetLength,
                                  range: Float(0.03)...Float(0.15),
                                  format: "%.3f m")
                        
                        // Base Z Dist: 全体の奥行きオフセット
                        sliderRow(title: "Base Z Dist",
                                  value: $handCoordinator.handBaseZ,
                                  range: Float(-1.0)...Float(1.0),
                                  format: "%.2f m")
                        
                        // Depth Compression: 手が遠いときの奥行き圧縮
                        // 0=全圧縮（手が奥に行かない）/ 1=圧縮なし（リアルな奥行き）
                        sliderRow(title: "Depth Compression",
                                  value: $handCoordinator.wristDepthCompression,
                                  range: Float(0.0)...Float(1.0),
                                  format: "%.2f")
                        
                        // Finger Depth Bias: 指先が沈みすぎる問題の補正
                        // 0=親関節と同じZ / 1=IK解をそのまま使用
                        sliderRow(title: "Finger Depth Bias",
                                  value: $handCoordinator.fingerDepthBias,
                                  range: Float(0.0)...Float(1.0),
                                  format: "%.2f")
                        
                        // Joint / Bone サイズ
                        sliderRow(title: "Joint Size",
                                  value: $handCoordinator.jointRadius,
                                  range: Float(0.001)...Float(0.02),
                                  format: "%.3f m")
                        
                        sliderRow(title: "Bone Thickness",
                                  value: $handCoordinator.boneRadius,
                                  range: Float(0.001)...Float(0.02),
                                  format: "%.3f m")
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
    
    // MARK: - Slider Helper
    private func sliderRow<V: BinaryFloatingPoint>(title: String,
                                                   value: Binding<V>,
                                                   range: ClosedRange<V>,
                                                   format: String) -> some View {
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

    // MARK: - IMU
    private func startIMU() {
        let mgr = GlassesManager.shared()
        _ = mgr.setupAndConnect()
        mgr.startPosePolling { x, y, z, qw, qx, qy, qz in
            let p = simd_float3(x, y, z)
            let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
            self.spacialCoordinator.updatePose(p: p, q: q)
        }
    }
}
