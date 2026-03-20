import Foundation
internal import AVFoundation
import SwiftUI
import Combine
import Vision

// MARK: - Hand Data Model
struct HandData: Identifiable {
    let id = UUID()
    var isRight: Bool
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    let indexTip: CGPoint?
    let distance: CGFloat
}

// MARK: - Camera Manager
class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var session = AVCaptureSession()
    @Published var hands: [HandData] = []
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "videoQueue", qos: .userInteractive)
    
    // Requestをプロパティとして保持し、毎フレームの生成コストを削減
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
            print("Camera Access Denied") // Typo fixed
        }
    }
    
    private func getVITUREcamera() -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        let position: AVCaptureDevice.Position
        
        deviceTypes = [.external, .builtInWideAngleCamera]
        position = .unspecified
        let discoverySession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: deviceTypes,
                    mediaType: .video,
                    position: position
        )
        let devices = discoverySession.devices
        if let externalCamera = devices.first(where: {
                    if #available(macOS 14.0, *) {
                        return $0.deviceType == .external
                    } else {
                        return $0.deviceType == .externalUnknown || $0.localizedName.localizedCaseInsensitiveContains("USB")
                    }
                }) {
                    print("📷 外付けカメラを選択しました: \(externalCamera.localizedName)")
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
            
            // TODO: 今後深度カメラを追加する際は、ここに AVCaptureDepthDataOutput の設定を追加します
            
        } catch {
            print("カメラエラー: \(error.localizedDescription)")
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
            
            // Vision
            var isRight = false
            // chirality is available from macOS 11.0 / iOS 14.0
            if #available(macOS 11.0, iOS 14.0, *) {
                // Because of Mirroring, Reverse
                isRight = observation.chirality == .left
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
                
                // X Position of Wrist as Center
                let centerX = points[.wrist]?.x ?? 0.5
                
                tempHands.append(TempHand(isRight: isRight, joints: points, indexTip: indexTip, distance: distance, centerX: centerX))
                
            } catch {
                print("Error acquiring Hands")
            }
        }
        
        // Stabilize (Typo fixed)
        if tempHands.count == 2 {
            // When Both hands detected, Left → Left Hand, Right → Right Hand
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
    
    // Calculate Depth
    private func getDepthDistance(joints: [VNHumanHandPoseObservation.JointName: CGPoint], indexTip: CGPoint?) -> CGFloat {
        guard let wrist = joints[.wrist], let middleMCP = joints[.middleMCP] else { return 1.0 }
        let dx = wrist.x - middleMCP.x
        let dy = wrist.y - middleMCP.y
        let size = sqrt(dx*dx + dy*dy)
        
        return 1.0 / max(size, 0.01)
    }
}

// MARK: - Calibration Data Models
struct CalibrationParams {
    var videoScale: CGFloat
    var videoOffsetX: CGFloat
    var videoOffsetY: CGFloat
    
    var offsetX: CGFloat
    var offsetY: CGFloat
    var scaleX: CGFloat
    var scaleY: CGFloat
    
    static let defaultLeft = CalibrationParams(
        videoScale: 1.90, videoOffsetX: 176, videoOffsetY: -368,
        offsetX: 0, offsetY: 0, scaleX: 1.0, scaleY: 1.0
    )
    
    static let defaultRight = CalibrationParams(
        videoScale: 1.90, videoOffsetX: -176, videoOffsetY: -368,
        offsetX: 0, offsetY: 0, scaleX: 1.0, scaleY: 1.0
    )
}

enum EyeViewMode: Hashable {
    case left
    case right
    case both
}

// MARK: - USBCameraModeView
struct USBCameraModeView: View {
    @Binding var currentMode: AppState
    @StateObject private var cameraManager = CameraManager()
    
    @State private var isSBSMode = true
    @State private var showVideo = false
    @State private var isAspectFit = true
    @State private var viewMode: EyeViewMode = .both
    @State private var isSettingsVisible = false
    
    @State private var leftParams = CalibrationParams.defaultLeft
    @State private var rightParams = CalibrationParams.defaultRight
    
    @State private var lineWidth: CGFloat = 4.0
    @State private var jointSize: CGFloat = 10.0
    
    // ★ 追加: スケルトンの視差（Parallax）調整用変数
    @State private var skeletonParallax: CGFloat = 10.0
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // メインビュー領域
            mainContentView
            
            // 戻るボタン
            BackButton(currentMode: $currentMode)
            
            // 設定パネル用オーバーレイ
            settingsOverlay
        }
        .onAppear {
            cameraManager.checkPermissions()
            // GlassesManager.shared().setupAndConnect()
        }
        .onDisappear {
            cameraManager.session.stopRunning()
        }
    }
    
    @ViewBuilder
    private var mainContentView: some View {
        if isSBSMode {
            HStack(spacing: 0) {
                if viewMode == .left || viewMode == .both {
                    eyeView(params: leftParams, label: viewMode == .both ? "Left Eye" : "", isLeft: true)
                } else {
                    Color.black
                }
                
                if viewMode == .right || viewMode == .both {
                    eyeView(params: rightParams, label: viewMode == .both ? "Right Eye" : "", isLeft: false)
                } else {
                    Color.black
                }
            }
        } else {
            if viewMode == .both {
                HStack(spacing: 0) {
                    eyeView(params: leftParams, label: "Left Eye", isLeft: true)
                    eyeView(params: rightParams, label: "Right Eye", isLeft: false)
                }
            } else {
                eyeView(params: viewMode == .left ? leftParams : rightParams, label: "", isLeft: viewMode == .left)
            }
        }
    }
    
    @ViewBuilder
    private var settingsOverlay: some View {
        HStack {
            Spacer()
            if isSettingsVisible {
                SettingsPanelView(
                    isSBSMode: $isSBSMode,
                    showVideo: $showVideo,
                    isAspectFit: $isAspectFit,
                    viewMode: $viewMode,
                    isSettingsVisible: $isSettingsVisible,
                    leftParams: $leftParams,
                    rightParams: $rightParams,
                    lineWidth: $lineWidth,
                    jointSize: $jointSize,
                    skeletonParallax: $skeletonParallax
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) {
                            isSettingsVisible = true
                        }
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .shadow(radius: 5)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding()
                    .padding(.bottom, 20)
                }
            }
        }
        .padding()
    }
    
    @ViewBuilder
    private func eyeView(params: CalibrationParams, label: String, isLeft: Bool) -> some View {
        ZStack {
            if showVideo {
                CameraPreviewView(session: cameraManager.session, isAspectFit: isAspectFit)
                    .scaleEffect(params.videoScale)
                    .offset(x: params.videoOffsetX, y: params.videoOffsetY)
                    .edgesIgnoringSafeArea(.all)
            }
            
            if !cameraManager.hands.isEmpty {
                ForEach(cameraManager.hands) { hand in
                    
                    // ★ 左目ならマイナス方向、右目ならプラス方向に視差を加える
                    let currentParallax = isLeft ? -skeletonParallax : skeletonParallax
                    
                    HandSkeletonView(
                        joints: hand.joints,
                        isRight: hand.isRight,
                        offsetX: params.offsetX + currentParallax, // ★ 視差を適用
                        offsetY: params.offsetY,
                        scaleX: params.scaleX,
                        scaleY: params.scaleY,
                        lineWidth: lineWidth,
                        jointSize: jointSize
                    )
                    .scaleEffect(params.videoScale) // ビデオのスケールと同じスケールで拡大
                    .offset(x: params.videoOffsetX, y: params.videoOffsetY) // ビデオと同じ基本オフセットに追従
                }
            }
            
            if !label.isEmpty && !showVideo && isSettingsVisible {
                VStack {
                    Text(label)
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.3))
                        .padding()
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

// MARK: - Settings Panel View
struct SettingsPanelView: View {
    @Binding var isSBSMode: Bool
    @Binding var showVideo: Bool
    @Binding var isAspectFit: Bool
    @Binding var viewMode: EyeViewMode
    @Binding var isSettingsVisible: Bool
    
    @Binding var leftParams: CalibrationParams
    @Binding var rightParams: CalibrationParams
    
    @Binding var lineWidth: CGFloat
    @Binding var jointSize: CGFloat
    
    @Binding var skeletonParallax: CGFloat // ★ 追加
    
    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 12) {
                
                HStack {
                    Text("View Settings")
                        .font(.headline)
                        .foregroundColor(.green)
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) {
                            isSettingsVisible = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .frame(maxWidth: .infinity)
                
                Toggle("SBS Mode", isOn: $isSBSMode)
                    .toggleStyle(SwitchToggleStyle())
                
                Toggle("Show Camera Video", isOn: $showVideo)
                    .toggleStyle(SwitchToggleStyle())
                
                Toggle("Aspect Fit", isOn: $isAspectFit)
                    .toggleStyle(SwitchToggleStyle())
                
                Divider().background(Color.white)
                
                Picker("Show...", selection: $viewMode) {
                    Text("Left").tag(EyeViewMode.left)
                    Text("Right").tag(EyeViewMode.right)
                    Text("Both").tag(EyeViewMode.both)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.vertical, 5)
                
                if viewMode == .left {
                    calibrationContent(title: "Adjust Left", params: $leftParams, color: .cyan, isLeft: true)
                } else if viewMode == .right {
                    calibrationContent(title: "Adjust Right", params: $rightParams, color: .orange, isLeft: false)
                } else {
                    Text("In Both, individual adjustment panels are hidden.\nChoose either to adjust.")
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.trailing)
                        .padding(.vertical, 20)
                }
                
                Divider().background(Color.white)
                
                Text("3. Skeleton Parallax (Depth)")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundColor(.yellow)
                
                HStack {
                    Text(String(format: "Parallax: %.0f", skeletonParallax))
                        .frame(width: 100, alignment: .leading)
                    Slider(value: $skeletonParallax, in: -300...300)
                }
                Text("値を大きくすると、左は左へ、右は右へ移動し、より奥にあるように見えます。")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                
                Divider().background(Color.white)
                
                Text("View")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                HStack {
                    Text(String(format: "Line Thickness: %.1f", lineWidth))
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $lineWidth, in: 1...20)
                }
                
                HStack {
                    Text(String(format: "Point Size: %.1f", jointSize))
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $jointSize, in: 1...30)
                }
            }
            .font(.caption)
            .padding()
        }
        .frame(width: 340, height: 650) // 少し高さを広げました
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .foregroundColor(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
    }
    
    @ViewBuilder
    private func calibrationContent(title: String, params: Binding<CalibrationParams>, color: Color, isLeft: Bool) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(color)
        
        Text("1. Camera Video Adjustment")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        
        HStack {
            Text(String(format: "Magnification: %.2f", params.videoScale.wrappedValue))
                .frame(width: 100, alignment: .leading)
            Slider(value: params.videoScale, in: 0.1...5.0)
        }
        
        HStack {
            Text("X Adjustment: \(Int(params.videoOffsetX.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.videoOffsetX, in: -1000...1000)
        }
        
        HStack {
            Text("Y Adjustment: \(Int(params.videoOffsetY.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.videoOffsetY, in: -1000...1000)
        }
        
        Divider().background(Color.white)
        
        Text("2. Skeleton Transform")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        
        HStack {
            Text(String(format: "Width: %.2f", params.scaleX.wrappedValue))
                .frame(width: 100, alignment: .leading)
            Slider(value: params.scaleX, in: 0.1...3.0)
        }
        
        HStack {
            Text(String(format: "Height: %.2f", params.scaleY.wrappedValue))
                .frame(width: 100, alignment: .leading)
            Slider(value: params.scaleY, in: 0.1...3.0)
        }
        
        HStack {
            Text("X: \(Int(params.offsetX.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.offsetX, in: -1000...1000)
        }
        
        HStack {
            Text("Y: \(Int(params.offsetY.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.offsetY, in: -1000...1000)
        }
        
        Button(action: {
            params.wrappedValue = isLeft ? CalibrationParams.defaultLeft : CalibrationParams.defaultRight
        }) {
            Text("Reset to best")
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(color)
                .foregroundColor(.black)
                .cornerRadius(8)
                .fontWeight(.bold)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.top, 5)
    }
}

// MARK: - Camera Preview Components
struct CameraPreviewView: NSViewRepresentable {
    var session: AVCaptureSession
    var isAspectFit: Bool
    
    func makeNSView(context: Context) -> VideoPreviewNSView {
        let view = VideoPreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = isAspectFit ? .resizeAspect : .resizeAspectFill
        return view
    }
    
    func updateNSView(_ nsView: VideoPreviewNSView, context: Context) {
        nsView.previewLayer.session = session
        nsView.previewLayer.videoGravity = isAspectFit ? .resizeAspect : .resizeAspectFill
    }
}

class VideoPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    
    override init(frame frameRect: NSRect) {
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

// MARK: - Hand Skeleton View
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
    
    var handColor: Color {
        return isRight ? .orange : .cyan
    }
    var glowColor: Color {
        return isRight ? .red : .blue
    }
    
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
