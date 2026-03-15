import Foundation
import AVFoundation
import SwiftUI
import Combine
import Vision

// MARK: - Hand Data Model (左右の区別と距離情報を持つ)
struct HandData: Identifiable {
    let id = UUID()
    var isRight: Bool
    let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
    let indexTip: CGPoint?
    let distance: CGFloat // 深度カメラ等から取得した距離データ
}

// MARK: - Camera Manager
class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var session = AVCaptureSession()
    @Published var hands: [HandData] = []
    
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "videoQueue", qos: .userInteractive)
    
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
            print("カメラへのアクセスが拒否されています")
        }
    }
    
    private func setupCamera() {
        session.beginConfiguration()
        
        guard let device = AVCaptureDevice.default(for: .video) else {
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
        let request = VNDetectHumanHandPoseRequest { [weak self] request, error in
            self?.processHandPose(request: request)
        }
        
        request.maximumHandCount = 2 // 両手まで検出可能
        
        do {
            try handler.perform([request])
        } catch {
            print("Visionエラー: \(error)")
        }
    }
    
    private func processHandPose(request: VNRequest) {
        guard let observations = request.results as? [VNHumanHandPoseObservation], !observations.isEmpty else {
            DispatchQueue.main.async { self.hands.removeAll() }
            return
        }
        
        // 処理中の一時的な手を保存する構造体
        struct TempHand {
            var isRight: Bool
            let joints: [VNHumanHandPoseObservation.JointName: CGPoint]
            let indexTip: CGPoint?
            let distance: CGFloat
            let centerX: CGFloat // 手首のX座標（左右判定の補正用）
        }
        
        var tempHands: [TempHand] = []
        
        for observation in observations {
            var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            
            // Vision AIによる初期判定
            var isRight = false
            if #available(iOS 15.0, *) {
                // カメラ映像をミラーリングしているため、判定を逆にする
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
                
                // 手首のX座標を位置基準として取得
                let centerX = points[.wrist]?.x ?? 0.5
                
                tempHands.append(TempHand(isRight: isRight, joints: points, indexTip: indexTip, distance: distance, centerX: centerX))
                
            } catch {
                print("関節の取得エラー")
            }
        }
        
        // ★ ここで左右の判定を安定化させる補正を行います
        if tempHands.count == 2 {
            // 両手が検出されている場合、画面の右側（X座標が大きい方）にある手を「右手」、
            // 左側にある手を「左手」として強制的に上書きして安定させます。
            if tempHands[0].centerX > tempHands[1].centerX {
                tempHands[0].isRight = true
                tempHands[1].isRight = false
            } else {
                tempHands[0].isRight = false
                tempHands[1].isRight = true
            }
        }
        
        // 最終的なデータに変換
        var detectedHands: [HandData] = []
        for temp in tempHands {
            detectedHands.append(HandData(
                isRight: temp.isRight,
                joints: temp.joints,
                indexTip: temp.indexTip,
                distance: temp.distance
            ))
        }
        
        DispatchQueue.main.async {
            self.hands = detectedHands
        }
    }
    
    /// 人差し指の位置や手の大きさから距離(深度)を計算する関数
    /// （後で深度カメラの値に置き換えるためのプレースホルダーです）
    private func getDepthDistance(joints: [VNHumanHandPoseObservation.JointName: CGPoint], indexTip: CGPoint?) -> CGFloat {
        // TODO: ここに深度カメラ（LiDARやステレオ）から実際の距離(m)を取得する処理を記述します。
        // 引数の indexTip (人差し指の先端) の座標を使って深度マップから値を引き抜く流れになります。
        
        // 現在はダミーとして、手の「画面上の大きさ」から擬似的に距離を推定しています。
        guard let wrist = joints[.wrist], let middleMCP = joints[.middleMCP] else { return 1.0 }
        let dx = wrist.x - middleMCP.x
        let dy = wrist.y - middleMCP.y
        let size = sqrt(dx*dx + dy*dy) // 手の大きさ
        
        // 手が大きい(size大) = 近い(distance小) となるように計算
        // 後で実際のメートル単位などに差し替えてください
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
        videoScale: 1.98, videoOffsetX: 154, videoOffsetY: -372,
        offsetX: 0, offsetY: 0, scaleX: 1.0, scaleY: 1.0
    )
    
    static let defaultRight = CalibrationParams(
        videoScale: 2.11, videoOffsetX: -92, videoOffsetY: -366,
        offsetX: 0, offsetY: 0, scaleX: 1.0, scaleY: 1.0
    )
}

enum EyeViewMode: Hashable {
    case left
    case right
    case both
}

// MARK: - 2. USB Camera Mode View
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
    
    // 距離に対する視差の強さを決める係数
    @State private var parallaxMultiplier: CGFloat = 20.0
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
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
            
            BackButton(currentMode: $currentMode)
            
            // UIパネルと設定ボタン
            HStack {
                Spacer()
                if isSettingsVisible {
                    unifiedPanel
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
        .onAppear {
            cameraManager.checkPermissions()
        }
        .onDisappear {
            cameraManager.session.stopRunning()
        }
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
                    // 計算式: 視差 = 係数 / 距離 (手が近いほど視差が大きくなる)
                    // 後で深度カメラを繋いだ時も、この parallaxMultiplier を調整すればキャリブレーション可能
                    let calculatedParallax = parallaxMultiplier / max(hand.distance, 0.1)
                    let currentParallax = isLeft ? calculatedParallax : -calculatedParallax
                    
                    HandSkeletonView(
                        joints: hand.joints,
                        isRight: hand.isRight,
                        offsetX: params.offsetX + currentParallax, // 視差を足す
                        offsetY: params.offsetY,
                        scaleX: params.scaleX,
                        scaleY: params.scaleY,
                        lineWidth: lineWidth,
                        jointSize: jointSize
                    )
                    .scaleEffect(params.videoScale)
                    .offset(x: params.videoOffsetX, y: params.videoOffsetY)
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
    
    var unifiedPanel: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 12) {
                
                HStack {
                    Text("表示・全体設定")
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
                
                Toggle("左右分割 (SBS) モード", isOn: $isSBSMode)
                    .toggleStyle(SwitchToggleStyle())
                
                Toggle("カメラ映像を表示", isOn: $showVideo)
                    .toggleStyle(SwitchToggleStyle())
                
                Toggle("全体を表示 (Aspect Fit)", isOn: $isAspectFit)
                    .toggleStyle(SwitchToggleStyle())
                
                Divider().background(Color.white)
                
                Picker("表示・調整対象", selection: $viewMode) {
                    Text("左目のみ").tag(EyeViewMode.left)
                    Text("右目のみ").tag(EyeViewMode.right)
                    Text("両目(確認)").tag(EyeViewMode.both)
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.vertical, 5)
                
                if viewMode == .left {
                    calibrationContent(title: "左目の調整", params: $leftParams, color: .cyan, isLeft: true)
                } else if viewMode == .right {
                    calibrationContent(title: "右目の調整", params: $rightParams, color: .orange, isLeft: false)
                } else {
                    Text("両目モードでは個別の調整パネルを隠しています。\n左右どちらかを選択して微調整してください。")
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.trailing)
                        .padding(.vertical, 20)
                }
                
                Divider().background(Color.white)
                
                Text("見た目と3Dの調整 (左右共通)")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                // 深度と視差のキャリブレーション用スライダー
                HStack {
                    Text(String(format: "3D視差の強さ: %.1f", parallaxMultiplier))
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $parallaxMultiplier, in: 0...100)
                }
                    
                HStack {
                    Text(String(format: "線の太さ: %.1f", lineWidth))
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $lineWidth, in: 1...20)
                }
                
                HStack {
                    Text(String(format: "点のサイズ: %.1f", jointSize))
                        .frame(width: 140, alignment: .leading)
                    Slider(value: $jointSize, in: 1...30)
                }
            }
            .font(.caption)
            .padding()
        }
        .frame(width: 340, height: 600)
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
        
        Text("1. カメラ映像・スケルトンの表示領域")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 5)
        
        HStack {
            Text(String(format: "拡大率: %.2f", params.videoScale.wrappedValue))
                .frame(width: 100, alignment: .leading)
            Slider(value: params.videoScale, in: 0.1...5.0)
        }
        
        HStack {
            Text("Xズレ: \(Int(params.videoOffsetX.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.videoOffsetX, in: -1000...1000)
        }
        
        HStack {
            Text("Yズレ: \(Int(params.videoOffsetY.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.videoOffsetY, in: -1000...1000)
        }
        
        Divider().background(Color.white)
        
        Text("2. スケルトン単体の微調整")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        
        HStack {
            Text(String(format: "幅: %.2f", params.scaleX.wrappedValue))
                .frame(width: 100, alignment: .leading)
            Slider(value: params.scaleX, in: 0.1...3.0)
        }
        
        HStack {
            Text(String(format: "高さ: %.2f", params.scaleY.wrappedValue))
                .frame(width: 100, alignment: .leading)
            Slider(value: params.scaleY, in: 0.1...3.0)
        }
        
        HStack {
            Text("単体Xズレ: \(Int(params.offsetX.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.offsetX, in: -1000...1000)
        }
        
        HStack {
            Text("単体Yズレ: \(Int(params.offsetY.wrappedValue))")
                .frame(width: 100, alignment: .leading)
            Slider(value: params.offsetY, in: -1000...1000)
        }
        
        Button(action: {
            params.wrappedValue = isLeft ? CalibrationParams.defaultLeft : CalibrationParams.defaultRight
        }) {
            Text("最適値にリセット")
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
    var isRight: Bool // 右手か左手か
    
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
    
    // 右手と左手で色を変える
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
