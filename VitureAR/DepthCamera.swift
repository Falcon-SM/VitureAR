import Foundation
import CoreVideo
import CoreImage
import SwiftUI
import Combine
import Vision

/*
// MARK: - Camera View Model
class CameraViewModel: ObservableObject {
    @Published var leftFrame: CGImage?
    @Published var rightFrame: CGImage?
    
    @Published var leftIndexTip: CGPoint?
    @Published var rightIndexTip: CGPoint?
    
    @Published var estimatedZDistance: CGFloat?
    
    private let depthMultiplier: CGFloat = 3.44
    private let disparityOffset: CGFloat = 0.175
    
    func processBuffers(left: CVPixelBuffer, right: CVPixelBuffer) {
        let leftImage = convertToCGImage(pixelBuffer: left)
        let rightImage = convertToCGImage(pixelBuffer: right)
        
        let lTip = detectIndexTip(in: left)
        let rTip = detectIndexTip(in: right)
        
        var zDist: CGFloat? = nil

        if let l = lTip, let r = rTip {
            let realDisparity = (l.x - r.x) - disparityOffset
            if realDisparity > 0.001 {
                let rawZ = depthMultiplier / realDisparity
                if rawZ > 15.0 {
                    zDist = rawZ + ((rawZ - 15.0) * 0.25)
                } else {
                    zDist = rawZ
                }
            }
        }
        
        DispatchQueue.main.async {
            self.leftFrame = leftImage
            self.rightFrame = rightImage
            self.leftIndexTip = lTip
            self.rightIndexTip = rTip
            self.estimatedZDistance = zDist
        }
    }
    
    private func detectIndexTip(in pixelBuffer: CVPixelBuffer) -> CGPoint? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let indexTipPoint = try observation.recognizedPoint(.indexTip)
            
            if indexTipPoint.confidence > 0.3 {
                return CGPoint(x: indexTipPoint.location.x, y: 1.0 - indexTipPoint.location.y)
            }
        } catch {
            print("Hand tracking error: \(error)")
        }
        return nil
    }
    
    private func convertToCGImage(pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        return context.makeImage()
    }
}

// MARK: - 1. Depth Camera Mode View (VITURE Glasses用)
struct ARContentView: View {
    @Binding var currentMode: AppState
    @StateObject private var viewModel = CameraViewModel()
    // （GlassesManagerが有効な場合はコメントを外してください）
    private let manager = GlassesManager.shared()
    
    private let cameraWidth: CGFloat = 640
    private let cameraHeight: CGFloat = 480

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                CameraOverlayView(
                    cgImage: viewModel.leftFrame,
                    indexTip: viewModel.leftIndexTip,
                    distance: viewModel.estimatedZDistance,
                    isLeft: true
                )
                .frame(width: cameraWidth, height: cameraHeight)
                
                CameraOverlayView(
                    cgImage: viewModel.rightFrame,
                    indexTip: viewModel.rightIndexTip,
                    distance: viewModel.estimatedZDistance,
                    isLeft: false
                )
                .frame(width: cameraWidth, height: cameraHeight)
            }
            .frame(width: cameraWidth * 2, height: cameraHeight)
            .background(Color.black)
            
            BackButton(currentMode: $currentMode)
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            if manager?.setupAndConnect() == true {
                manager?.startStreaming { left, right in
                    if let leftBuffer = left, let rightBuffer = right {
                        viewModel.processBuffers(left: leftBuffer, right: rightBuffer)
                    }
                }
            } else {
                print("VITURE Glassesの接続に失敗しました")
            }
        }
    }
}

struct CameraOverlayView: View {
    let cgImage: CGImage?
    let indexTip: CGPoint?
    let distance: CGFloat?
    let isLeft: Bool
    
    private func getPixelPosition(for tip: CGPoint, in size: CGSize) -> CGPoint {
        let imageAspect = 640.0 / 480.0
        let viewAspect = size.width / size.height
        
        var drawWidth = size.width
        var drawHeight = size.height
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        
        if viewAspect > imageAspect {
            drawWidth = drawHeight * imageAspect
            offsetX = (size.width - drawWidth) / 2.0
        } else {
            drawHeight = drawWidth / imageAspect
            offsetY = (size.height - drawHeight) / 2.0
        }
        return CGPoint(x: offsetX + tip.x * drawWidth, y: offsetY + tip.y * drawHeight)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = cgImage {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                        .overlay(Text(isLeft ? "Left Camera" : "Right Camera").foregroundColor(.white))
                }
                
                if let tip = indexTip {
                    let pos = getPixelPosition(for: tip, in: geometry.size)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 20, height: 20)
                        .position(x: pos.x, y: pos.y)
                        .shadow(color: .red, radius: 10)
                    
                    if let z = distance {
                        Text(String(format: "%.1f cm", z))
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.yellow)
                            .padding(8)
                            .background(Color.black.opacity(0.7))
                            .cornerRadius(8)
                            .position(x: pos.x, y: pos.y - 40)
                    }
                }
            }
        }
        .background(Color.black)
    }
}
*/


// MARK: - Camera View Model
class CameraViewModel: ObservableObject {
    @Published var leftFrame: CGImage?
    @Published var rightFrame: CGImage?
    
    @Published var leftIndexTip: CGPoint?
    @Published var rightIndexTip: CGPoint?
    
    @Published var estimatedZDistance: CGFloat?
    
    private let depthMultiplier: CGFloat = 3.44
    private let disparityOffset: CGFloat = 0.175
    
    func processBuffers(left: CVPixelBuffer, right: CVPixelBuffer) {
        let leftImage = convertToCGImage(pixelBuffer: left)
        let rightImage = convertToCGImage(pixelBuffer: right)
        
        let lTip = detectIndexTip(in: left)
        let rTip = detectIndexTip(in: right)
        
        var zDist: CGFloat? = nil

        if let l = lTip, let r = rTip {
            let realDisparity = (l.x - r.x) - disparityOffset
            if realDisparity > 0.001 {
                let rawZ = depthMultiplier / realDisparity
                if rawZ > 15.0 {
                    zDist = rawZ + ((rawZ - 15.0) * 0.25)
                } else {
                    zDist = rawZ
                }
            }
        }
        
        DispatchQueue.main.async {
            self.leftFrame = leftImage
            self.rightFrame = rightImage
            self.leftIndexTip = lTip
            self.rightIndexTip = rTip
            self.estimatedZDistance = zDist
        }
    }
    
    private func detectIndexTip(in pixelBuffer: CVPixelBuffer) -> CGPoint? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
            guard let observation = request.results?.first else { return nil }
            let indexTipPoint = try observation.recognizedPoint(.indexTip)
            
            if indexTipPoint.confidence > 0.3 {
                return CGPoint(x: indexTipPoint.location.x, y: 1.0 - indexTipPoint.location.y)
            }
        } catch {
            print("Hand tracking error: \(error)")
        }
        return nil
    }
    
    private func convertToCGImage(pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let context = CGContext(data: baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        return context.makeImage()
    }
}

// MARK: - 1. Depth Camera Mode View
struct ARContentView: View {
    @Binding var currentMode: AppState
    @StateObject private var viewModel = CameraViewModel()
    private let manager = GlassesManager.shared()
    
    private let cameraWidth: CGFloat = 640
    private let cameraHeight: CGFloat = 480
    
    // Parameters
    @State private var ipd: CGFloat = 64.0 // IPD (mm)
    @State private var virtualScreenDistance: CGFloat = 300.0 // Virtual Screen Distance (cm)

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                CameraOverlayView(
                    cgImage: viewModel.leftFrame,
                    indexTip: viewModel.leftIndexTip,
                    distance: viewModel.estimatedZDistance,
                    isLeft: true,
                    ipd: ipd,
                    screenDistance: virtualScreenDistance
                )
                .frame(width: cameraWidth, height: cameraHeight)
                
                CameraOverlayView(
                    cgImage: viewModel.rightFrame,
                    indexTip: viewModel.rightIndexTip,
                    distance: viewModel.estimatedZDistance,
                    isLeft: false,
                    ipd: ipd,
                    screenDistance: virtualScreenDistance
                )
                .frame(width: cameraWidth, height: cameraHeight)
            }
            .frame(width: cameraWidth * 2, height: cameraHeight)
            .background(Color.black)
            
            // Controll Panels
            VStack {
                Spacer()
                HStack(spacing: 40) {
                    VStack {
                        Text(String(format: "IPD: %.1f mm", ipd)).foregroundColor(.white).font(.caption)
                        Slider(value: $ipd, in: 50...75)
                    }
                    .frame(width: 200)
                    
                    VStack {
                        Text(String(format: "Screen Dist: %.0f cm", virtualScreenDistance)).foregroundColor(.white).font(.caption)
                        Slider(value: $virtualScreenDistance, in: 100...500)
                    }
                    .frame(width: 200)
                }
                .padding()
                .background(Color.black.opacity(0.6))
                .cornerRadius(12)
                .padding(.bottom, 30)
            }
            
            BackButton(currentMode: $currentMode)
        }
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            if manager?.setupAndConnect() == true {
                manager?.startStreaming { left, right in
                    if let leftBuffer = left, let rightBuffer = right {
                        viewModel.processBuffers(left: leftBuffer, right: rightBuffer)
                    }
                }
            } else {
                print("Failed connecting to VITURE Glasses")
            }
        }
    }
}

struct CameraOverlayView: View {
    let cgImage: CGImage?
    let indexTip: CGPoint?
    let distance: CGFloat?
    let isLeft: Bool
    
    let ipd: CGFloat // mm
    let screenDistance: CGFloat // cm
    
    private func getPixelPosition(for tip: CGPoint, in size: CGSize) -> CGPoint {
        let imageAspect = 640.0 / 480.0
        let viewAspect = size.width / size.height
        
        var drawWidth = size.width
        var drawHeight = size.height
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        
        if viewAspect > imageAspect {
            drawWidth = drawHeight * imageAspect
            offsetX = (size.width - drawWidth) / 2.0
        } else {
            drawHeight = drawWidth / imageAspect
            offsetY = (size.height - drawHeight) / 2.0
        }
        return CGPoint(x: offsetX + tip.x * drawWidth, y: offsetY + tip.y * drawHeight)
    }
    
    // MARK: - Calculate Paarallax
    private func getParallaxOffset(zDistance: CGFloat, viewWidth: CGFloat) -> CGFloat {
        let ipdCm = ipd / 10.0 // mm -> cm
        let safeZ = max(zDistance, 1.0) // Zero
        
        let fovRadians = 52.0 * .pi / 180.0
        let screenWidthCm = 2.0 * screenDistance * tan(fovRadians / 2.0)
        let pixelsPerCm = viewWidth / screenWidthCm
        
        // (IPD / 2) * ( (ScreenZ / TargetZ) - 1 ) * pixelsPerCm
        let shift = (ipdCm / 2.0) * ((screenDistance / safeZ) - 1.0) * pixelsPerCm
        
        return isLeft ? shift : -shift
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = cgImage {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.gray.opacity(0.3)
                        .overlay(Text(isLeft ? "Left Camera" : "Right Camera").foregroundColor(.white))
                }
                
                if let z = distance {
                    if let tip = indexTip {
                        let pos = getPixelPosition(for: tip, in: geometry.size)
                        Circle()
                            .fill(Color.red)
                            .frame(width: 20, height: 20)
                            .position(x: pos.x, y: pos.y)
                            .shadow(color: .red, radius: 10)
                        
                        Text(String(format: "Hand\n%.1f cm", z))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.yellow)
                            .position(x: pos.x, y: pos.y - 30)
                    }
                    
                    let parallax = getParallaxOffset(zDistance: z, viewWidth: geometry.size.width)
                    let centerX = geometry.size.width / 2.0
                    let centerY = geometry.size.height / 2.0
                    
                    ZStack {
                        Circle()
                            .stroke(Color.cyan, lineWidth: 3)
                            .frame(width: 80, height: 80)
                        
                        Circle()
                            .fill(Color.cyan.opacity(0.3))
                            .frame(width: 40, height: 40)
                        
                        Image(systemName: "viewfinder")
                            .font(.system(size: 30))
                            .foregroundColor(.cyan)
                        
                        Text(String(format: "Virtual UI\n%.1f cm", z))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.cyan)
                            .offset(y: -60)
                    }

                    .position(x: centerX + parallax, y: centerY)
                    .shadow(color: .cyan, radius: 10)
                }
            }
        }
        .background(Color.black)
    }
}

