import SwiftUI
internal import AVFoundation
import Vision
import AppKit

// MARK: - 調整用パラメータ
struct CalibrationParams {
    var videoScale: CGFloat = 1.90
    var videoOffsetX: CGFloat = 0
    var videoOffsetY: CGFloat = -368
    
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
}

// MARK: - メインの調整用ビュー
struct USBCameraModeView: View {
    @Binding var currentMode: AppState
    
    @StateObject private var cameraManager = CameraManager()
    
    @State private var leftParams = CalibrationParams(videoOffsetX: 176)
    @State private var rightParams = CalibrationParams(videoOffsetX: -176)
    @State private var skeletonParallax: CGFloat = 10.0
    @State private var showSettings = true

    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            // SBS (サイドバイサイド) 画面
            HStack(spacing: 0) {
                eyeView(params: leftParams, isLeft: true)
                eyeView(params: rightParams, isLeft: false)
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
                let currentParallax = isLeft ? -skeletonParallax : skeletonParallax
                
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
                        Text("Left: \(Int(leftParams.videoOffsetX))")
                        Slider(value: $leftParams.videoOffsetX, in: -500...500)
                    }
                    HStack {
                        Text("Right: \(Int(rightParams.videoOffsetX))")
                        Slider(value: $rightParams.videoOffsetX, in: -500...500)
                    }
                }
                
                Divider()
                
                Group {
                    Text("Hand Depth Parallax").foregroundColor(.yellow)
                    HStack {
                        Text("\(Int(skeletonParallax))")
                        Slider(value: $skeletonParallax, in: -100...100)
                    }
                }
                
                Divider()
                
                Group {
                    Text("Hand Transform").foregroundColor(.yellow)
                    
                    // 左右で同じスケール・オフセットを共有して調整
                    HStack {
                        Text("Scale X/Y:")
                        Slider(value: $leftParams.scaleX, in: 0.1...3.0)
                            // ⚠️警告修正: 新しい onChange の構文
                            .onChange(of: leftParams.scaleX) { oldValue, newValue in
                                rightParams.scaleX = newValue
                                rightParams.scaleY = newValue
                                leftParams.scaleY = newValue
                            }
                    }
                    HStack {
                        Text("Offset X:")
                        Slider(value: $leftParams.offsetX, in: -500...500)
                            .onChange(of: leftParams.offsetX) { oldValue, newValue in
                                rightParams.offsetX = newValue
                            }
                    }
                    HStack {
                        Text("Offset Y:")
                        Slider(value: $leftParams.offsetY, in: -500...500)
                            .onChange(of: leftParams.offsetY) { oldValue, newValue in
                                rightParams.offsetY = newValue
                            }
                    }
                }
                
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
