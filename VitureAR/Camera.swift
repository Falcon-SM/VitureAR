import Foundation
import AVFoundation
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
            print("Camera Access Denyed")
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
        
        request.maximumHandCount = 2 // Both Hands can be Detected
        
        do {
            try handler.perform([request])
        } catch {
            print("Vision Error: \(error)")
        }
    }
    
    private func processHandPose(request: VNRequest) {
        guard let observations = request.results as? [VNHumanHandPoseObservation], !observations.isEmpty else {
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
            if #available(macOS 14.0, iOS 15.0, *) {
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
        
        // Stabalize
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
            
            // UI Panel, Settings
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
                    // Same Position
                    HandSkeletonView(
                        joints: hand.joints,
                        isRight: hand.isRight,
                        offsetX: params.offsetX,
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
                    Text("In Both, individual adjustment panels are hidden. \n Choose either to adjust.")
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.trailing)
                        .padding(.vertical, 20)
                }
                
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
        
        Text("1. Camera Video, Scelton Adjustment")
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
        
        Text("2. Scelton Adjustment")
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
