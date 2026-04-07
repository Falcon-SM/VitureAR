import AppKit
internal import AVFoundation
typealias NativeViewRepresentable = NSViewRepresentable
typealias SystemColor = NSColor

import SwiftUI
import RealityKit
import simd

// MARK: - ARView ラッパー
struct RawARView: NativeViewRepresentable {
    // 2つのコーディネーターを受け取って連携させます
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
        // AR機能をオフにした純粋な3Dビューとして初期化
        #if os(macOS)
        let arView = ARView(frame: .zero)
        #else
        let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
        #endif
        arView.environment.background = .color(SystemColor.black)
        
        // 左右のViewをSpacialCoordinatorに登録
        if isLeft {
            spacialCoordinator.leftView = arView
        } else {
            spacialCoordinator.rightView = arView
        }
        
        // 両方のViewが揃ったらシーンを構築してハンドトラッキングをセットアップ
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

    // 分離した2つのコーディネーターと、カメラマネージャーを用意
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
            // ハンドトラッキングにカメラマネージャーを渡す
            handCoordinator.cameraManager = cameraManager
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
                    Text("RealityKit + Hand Tracking")
                        .font(.headline)
                        .foregroundColor(.green)
                    
                    Text(String(format: "Pos: X:%.2f Y:%.2f Z:%.2f",
                                spacialCoordinator.debugPosition.x, spacialCoordinator.debugPosition.y, spacialCoordinator.debugPosition.z))
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
                    
                    Group {
                        Text("Glasses Display").font(.subheadline).foregroundColor(.yellow)
                        // SpacialCoordinatorのパラメータに繋ぎます
                        sliderRow(title: "IPD", value: $spacialCoordinator.ipd, range: 0.000...0.075, format: "%.3f m")
                        sliderRow(title: "FOV (Horizontal)", value: $spacialCoordinator.fieldOfView, range: 20.0...80.0, format: "%.1f°")
                        sliderRow(title: "Pos Scale", value: $spacialCoordinator.positionScale, range: 0.1...10.0, format: "%.2f")
                    }
                    
                    Divider().background(Color.gray)
                    
                    Group {
                        Text("Hand Transform").font(.subheadline).foregroundColor(.yellow)
                        // HandTrackingCoordinatorのパラメータに繋ぎます
                        sliderRow(title: "Scale X", value: $handCoordinator.handScaleX, range: 0.1...3.0, format: "%.2f")
                        sliderRow(title: "Scale Y", value: $handCoordinator.handScaleY, range: 0.1...3.0, format: "%.2f")
                        sliderRow(title: "Offset X", value: $handCoordinator.handOffsetX, range: -1.0...1.0, format: "%.2f")
                        sliderRow(title: "Offset Y", value: $handCoordinator.handOffsetY, range: -1.0...1.0, format: "%.2f")
                    }
                    
                    Divider().background(Color.gray)
                    
                    Group {
                        Text("Hand Depth & Size").font(.subheadline).foregroundColor(.yellow)
                        sliderRow(title: "Base Z Dist", value: $handCoordinator.handBaseZ, range: -1.0...0.0, format: "%.2f m")
                        sliderRow(title: "Depth Multiplier", value: $handCoordinator.handDepthMultiplier, range: 0.0...0.1, format: "%.3f")
                        sliderRow(title: "Joint Size", value: $handCoordinator.jointRadius, range: 0.001...0.02, format: "%.3f")
                        sliderRow(title: "Bone Thickness", value: $handCoordinator.boneRadius, range: 0.001...0.02, format: "%.3f")
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
            let p = simd_float3(x, y, z)
            let q = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
            // Send Data to SpacialCoordinator
            self.spacialCoordinator.updatePose(p: p, q: q)
        }
    }
}
