import SwiftUI
import Combine
internal import AVFoundation
import Vision
import AppKit

// MARK: - 調整用パラメータ
struct CalibrationParams: Codable {
    var videoScale: CGFloat = 1.90
    var videoOffsetX: CGFloat = 0
    var videoOffsetY: CGFloat = -368
    
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0

    var leftParallax: CGFloat = -11.0
    var rightParallax: CGFloat = 10.0
}

private enum CalibrationKeys {
    static let left = "calibration.leftParams"
    static let right = "calibration.rightParams"
}

final class CalibrationViewModel: ObservableObject {
    @Published var leftParams = CalibrationParams(videoOffsetX: 207) {
        didSet { save() }
    }
    @Published var rightParams = CalibrationParams(videoOffsetX: -176) {
        didSet { save() }
    }

    init() {
        load()
    }

    private func save() {
        let encoder = JSONEncoder()
        if let leftData = try? encoder.encode(leftParams) {
            UserDefaults.standard.set(leftData, forKey: CalibrationKeys.left)
        }
        if let rightData = try? encoder.encode(rightParams) {
            UserDefaults.standard.set(rightData, forKey: CalibrationKeys.right)
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        if let leftData = UserDefaults.standard.data(forKey: CalibrationKeys.left),
           let decodedLeft = try? decoder.decode(CalibrationParams.self, from: leftData) {
            leftParams = decodedLeft
        }
        if let rightData = UserDefaults.standard.data(forKey: CalibrationKeys.right),
           let decodedRight = try? decoder.decode(CalibrationParams.self, from: rightData) {
            rightParams = decodedRight
        }
    }
    
    func resetHandTransforms() {
        // Left
        leftParams.offsetX = 0
        leftParams.offsetY = 0
        leftParams.scaleX = 1
        leftParams.scaleY = 1
        leftParams.leftParallax = 0
        // Right
        rightParams.offsetX = 0
        rightParams.offsetY = 0
        rightParams.scaleX = 1
        rightParams.scaleY = 1
        rightParams.rightParallax = 0
        // Save after resetting
        save()
    }
}

// MARK: - メインの調整用ビュー
struct USBCameraModeView: View {
    @Binding var currentMode: AppState
    
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var calibration = CalibrationViewModel()
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // SBS (サイドバイサイド) 画面
            HStack(spacing: 0) {
                eyeView(params: calibration.leftParams, isLeft: true)
                eyeView(params: calibration.rightParams, isLeft: false)
            }
            .edgesIgnoringSafeArea(.all)
            
            // 設定パネル表示ボタン
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { withAnimation { showSettings.toggle() } }) {
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
            
            // 設定パネル
            if showSettings {
                HStack {
                    calibrationPanel
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Spacer()
                }
            }
        }
        .onAppear {
            cameraManager.checkPermissions()
        }
        .onDisappear {
            cameraManager.session.stopRunning()
        }
    }
    
    // 片目ぶんの映像と骨格を描画する部分
    @ViewBuilder
    private func eyeView(params: CalibrationParams, isLeft: Bool) -> some View {
        ZStack {
            // カメラ映像 (背景)
            CameraPreviewView(session: cameraManager.session)
                .scaleEffect(params.videoScale)
                .offset(x: params.videoOffsetX, y: params.videoOffsetY)
            
            // 手の骨格描画 (HandTracking.swift の HandSkeletonView を呼び出し)
            ForEach(cameraManager.hands) { hand in
                let currentParallax = isLeft ? -calibration.leftParams.leftParallax : calibration.rightParams.rightParallax
                
                HandSkeletonView(
                    joints: hand.joints,
                    isRight: hand.isRight,
                    offsetX: params.offsetX + currentParallax,
                    offsetY: params.offsetY,
                    scaleX: params.scaleX,
                    scaleY: params.scaleY,
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
    
    // MARK: - 調整パネル UI
    private var calibrationPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text("Calibration (L/R Shared)")
                    .font(.headline)
                    .foregroundColor(.green)
                
                Group {
                    Text("Video Offset X").foregroundColor(.yellow)
                    HStack {
                        Text("Left: \(Int(calibration.leftParams.videoOffsetX))")
                        Slider(value: $calibration.leftParams.videoOffsetX, in: -500...500)
                    }
                    HStack {
                        Text("Right: \(Int(calibration.rightParams.videoOffsetX))")
                        Slider(value: $calibration.rightParams.videoOffsetX, in: -500...500)
                    }
                }
                
                Divider()
                
                Group {
                    Text("Hand Depth Parallax").foregroundColor(.yellow)
                    HStack {
                        Text("Left: \(Int(calibration.leftParams.leftParallax))")
                        Slider(value: $calibration.leftParams.leftParallax, in: -100...100)
                    }
                    HStack {
                        Text("Right: \(Int(calibration.rightParams.rightParallax))")
                        Slider(value: $calibration.rightParams.rightParallax, in: -100...100)
                    }
                }
                
                Divider()
                
                Group {
                    Text("Hand Transform").foregroundColor(.yellow)
                    
                    // 左右で同じスケール・オフセットを共有して調整
                    HStack {
                        Text("Scale X/Y:")
                        Slider(value: $calibration.leftParams.scaleX, in: 0.1...3.0)
                            // ⚠️警告修正: 新しい onChange の構文
                            .onChange(of: calibration.leftParams.scaleX) { oldValue, newValue in
                                calibration.rightParams.scaleX = newValue
                                calibration.rightParams.scaleY = newValue
                                calibration.leftParams.scaleY = newValue
                            }
                    }
                    HStack {
                        Text("Offset X:")
                        Slider(value: $calibration.leftParams.offsetX, in: -500...500)
                            .onChange(of: calibration.leftParams.offsetX) { oldValue, newValue in
                                calibration.rightParams.offsetX = newValue
                            }
                    }
                    HStack {
                        Text("Offset Y:")
                        Slider(value: $calibration.leftParams.offsetY, in: -500...500)
                            .onChange(of: calibration.leftParams.offsetY) { oldValue, newValue in
                                calibration.rightParams.offsetY = newValue
                            }
                    }
                }
                
                Button("Reset to Vision (no transforms)") {
                    calibration.resetHandTransforms()
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 4)
                
                Button("Close Panel") {
                    withAnimation { showSettings = false }
                }
                .padding(.top, 10)
            }
            .font(.caption)
            .padding()
        }
        .frame(width: 250)
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .foregroundColor(.white)
        .padding()
    }
}

// MARK: - Camera Preview Components (Mac専用に修正)
struct CameraPreviewView: NSViewRepresentable {
    var session: AVCaptureSession
    
    func makeNSView(context: Context) -> VideoPreviewNativeView {
        let view = VideoPreviewNativeView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect // アスペクト比固定
        return view
    }
    
    func updateNSView(_ nsView: VideoPreviewNativeView, context: Context) {
        nsView.previewLayer.session = session
    }
}

class VideoPreviewNativeView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    
    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.addSublayer(previewLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        previewLayer.frame = self.bounds
    }
}

struct HandSkeletonView: View {
    var joints: [HandJoint: CGPoint]
    var isRight: Bool
    
    var offsetX: CGFloat
    var offsetY: CGFloat
    var scaleX: CGFloat
    var scaleY: CGFloat
    var lineWidth: CGFloat
    var jointSize: CGFloat
    
    let fingers: [[HandJoint]] = [
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
