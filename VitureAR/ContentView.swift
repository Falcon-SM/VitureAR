import SwiftUI
internal import AVFoundation

// MARK: - App Status
enum AppState {
    case launch
    case depthCamera
    case usbCamera
    case arMode
}

struct ContentView: View {
    @State private var currentMode: AppState = .launch
    @StateObject private var calibration = CalibrationViewModel()
    var body: some View {
        ZStack {
            switch currentMode {
            case .launch:
                LaunchView(currentMode: $currentMode)
            case .depthCamera:
                ARContentView(currentMode: $currentMode)
            case .usbCamera:
                USBCameraModeView(currentMode: $currentMode)
            case .arMode:
                ARModeView(currentMode: $currentMode)
            }
        }
        .environmentObject(calibration)
    }
}

// MARK: - Common Components
struct BackButton: View {
    @Binding var currentMode: AppState
    
    var body: some View {
        VStack {
            HStack {
                Button(action: {
                    GlassesManager.shared().disconnect()
                    withAnimation { currentMode = .launch }
                }) {
                    Image(systemName: "chevron.left")
                        .font(.title2)
                        .padding(12)
                        .background(Color.black.opacity(0.6))
                        .foregroundColor(.white)
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding()
                
                Spacer()
            }
            Spacer()
        }
    }
}

// MARK: - Start
struct LaunchView: View {
    @Binding var currentMode: AppState
    
    var body: some View {
        VStack(spacing: 50) {
            Text("VITURE AR Experience")
                .font(.system(size: 48, weight: .bold))
            
            VStack(spacing: 20) {
                MenuButton(
                    title: "1. Depth Camera",
                    subtitle: "Show Left/Right Camera movies and test distance calculation",
                    color: .blue
                ) {
                    currentMode = .depthCamera
                }
                
                MenuButton(
                    title: "2. USB Camera",
                    subtitle: "Overlay Hands' Scelton",
                    color: .purple
                ) {
                    currentMode = .usbCamera
                }
                
                MenuButton(
                    title: "3. AR Mode",
                    subtitle: "Under Development!",
                    color: .orange
                ) {
                    currentMode = .arMode
                }
            }
        }
        .frame(width: 800, height: 600)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct MenuButton: View {
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: {
            withAnimation { action() }
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.title2)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 20)
            .frame(width: 500)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(15)
        }
        .buttonStyle(PlainButtonStyle())
    }
}
