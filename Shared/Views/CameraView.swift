import AVFoundation
import SwiftUI

struct CameraView: View {
    @State private var camera = CameraModel()
    @State private var blackout = false
    @State private var showingViewer = false
    @State private var pinchBase: CGFloat?
    @State private var showingFormat = DemoMode.scene == "format"
    @Namespace private var viewerTransition
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @State private var orientation = DeviceOrientation()
    #endif

    /// Icons turn with the phone, like the native camera, while the layout stays put.
    private var iconAngle: Angle {
        #if os(iOS)
        orientation.iconAngle
        #else
        .zero
        #endif
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.authorization {
            case .authorized, .notDetermined:
                content
            default:
                PermissionView()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            #if DEBUG
            if let scene = DemoMode.scene {
                camera.enterDemo(scene)
                DemoMode.snapshotIfRequested()
                return
            }
            #endif
            await camera.start()
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            if phase == .active, !showingViewer {
                Task { await camera.start() }
            } else if phase == .background {
                camera.stop()
            }
            #endif
        }
        .onChange(of: showingViewer) { _, showing in
            if showing { camera.pause() } else { camera.resume() }
        }
        .onChange(of: camera.lastCaptureID) {
            // The native camera's quick black blink when a photo is taken.
            blackout = true
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) { blackout = false }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showingViewer) {
            // Opens out of the thumbnail and swipes down back into it, like the native camera.
            PhotoViewer { showingViewer = false }
                .zoomTransition(sourceID: "thumbnail", in: viewerTransition)
        }
        #else
        // On the Mac the viewer opens in the same window, as Photos does.
        .overlay {
            if showingViewer {
                PhotoViewer { showingViewer = false }
                    .transition(.asymmetric(insertion: .scale(scale: 0.97).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: showingViewer)
        #endif
    }

    private var content: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: 56)
                .padding(.horizontal, 16)

            viewfinder

            Spacer(minLength: 12)

            bottomBar
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 12)
                .overlay(alignment: .bottom) {
                    if showingFormat {
                        FormatPanel(formats: camera.availableFormats, format: camera.photoFormat,
                                    resolutions: camera.resolutions, resolution: camera.resolution,
                                    selectFormat: { camera.selectFormat($0) },
                                    selectResolution: { camera.selectResolution($0) },
                                    close: closeFormat)
                            .padding(.horizontal, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
        }
        // Tapping anywhere outside the Format panel closes it, as in the native camera.
        .background {
            if showingFormat {
                Color.black.opacity(0.001).onTapGesture(perform: closeFormat)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: iconAngle)
        #if os(macOS)
        .background {
            Button("") {
                if showingFormat { closeFormat() } else if !showingViewer { camera.shutterPressed() }
            }
            .keyboardShortcut(.space, modifiers: [])
            .opacity(0)
            Button("") { closeFormat() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        }
        #endif
    }

    private func closeFormat() {
        withAnimation(.spring(duration: 0.35)) { showingFormat = false }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Spacer()

            HStack(spacing: 22) {
                FormatButton(format: camera.photoFormat, resolution: camera.resolution) {
                    withAnimation(.spring(duration: 0.35)) { showingFormat.toggle() }
                }
                .rotationEffect(iconAngle)
                if camera.hasFlash {
                    GlassIconButton(symbol: camera.flash.symbol,
                                    foreground: camera.flash == .off ? .white : .yellow) {
                        camera.flash = camera.flash.next
                    }
                    .rotationEffect(iconAngle)
                    .accessibilityLabel("Flash \(camera.flash == .auto ? "automatic" : camera.flash == .on ? "on" : "off")")
                }
            }

            Spacer()

            #if os(macOS)
            cameraMenu
            #endif
        }
    }

    #if os(macOS)
    private var cameraMenu: some View {
        Menu {
            ForEach(camera.cameras, id: \.uniqueID) { device in
                Button {
                    camera.selectCamera(device)
                } label: {
                    if device.uniqueID == camera.currentCameraID {
                        Label(device.localizedName, systemImage: "checkmark")
                    } else {
                        Text(device.localizedName)
                    }
                }
            }
        } label: {
            Image(systemName: "web.camera")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .glass(in: Circle())
        .help("Choose camera")
        .disabled(camera.cameras.count < 2)
    }
    #endif

    // MARK: - Viewfinder

    private var viewfinder: some View {
        Group {
            if DemoMode.scene != nil {
                DemoScene(lookingAway: DemoMode.scene == "waiting" ? [1] : [],
                          tilt: DemoMode.scene == "posing" ? [0: 12, 1: -6, 2: -13] : [:])
            } else {
                PreviewLayerView(layer: camera.previewLayer)
            }
        }
            .aspectRatio(camera.frameAspect, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { location in
                            if showingFormat {
                                closeFormat()
                            } else if geo.size.width > 0, geo.size.height > 0 {
                                camera.focus(at: CGPoint(x: location.x / geo.size.width, y: location.y / geo.size.height))
                            }
                        }
                    if let point = camera.focusPoint {
                        FocusSquare()
                            .id(camera.focusID)
                            .position(x: point.x * geo.size.width, y: point.y * geo.size.height)
                    }
                }
            }
            .overlay {
                FaceOverlay(faces: camera.readiness.faces,
                            armed: camera.smartShotState == .armed)
            }
            .overlay(alignment: .top) {
                if camera.smartShotRunning {
                    SmartShotStatusPill(state: camera.smartShotState, readiness: camera.readiness,
                                        count: camera.smartShotCount)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let error = camera.errorMessage {
                    Text(error)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                        .padding(.top, 12)
                        .transition(.opacity)
                        .task(id: error) {
                            try? await Task.sleep(for: .seconds(3))
                            camera.errorMessage = nil
                        }
                }
            }
            .overlay(alignment: .bottom) {
                if camera.zoomStops.count > 1 {
                    ZoomBar(stops: camera.zoomStops, current: camera.displayZoom, iconAngle: iconAngle) {
                        camera.selectZoom($0)
                    }
                    .padding(.bottom, 14)
                }
            }
            .overlay {
                if let message = camera.interruptionMessage {
                    ZStack {
                        Color.black.opacity(0.75)
                        VStack(spacing: 10) {
                            Image(systemName: "video.slash.fill").font(.system(size: 30))
                            Text(message).font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                Color.black.opacity(blackout ? 1 : 0).allowsHitTesting(false)
            }
            .animation(.snappy, value: camera.smartShotState)
            .animation(.easeOut(duration: 0.2), value: camera.interruptionMessage)
            .animation(.easeOut(duration: 0.2), value: camera.errorMessage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(iOS)
            .simultaneousGesture(pinchToZoom)
            #endif
    }

    #if os(iOS)
    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? camera.displayZoom
                pinchBase = base
                camera.setDisplayZoom(base * value.magnification)
            }
            .onEnded { _ in pinchBase = nil }
    }
    #endif

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            ThumbnailButton(image: camera.lastImage) { showingViewer = true }
                .zoomTransitionSource(id: "thumbnail", in: viewerTransition)
                .rotationEffect(iconAngle)
                .accessibilityLabel("Photos")

            Spacer()

            ShutterButton(smartShot: camera.smartShotState,
                          holdProgress: holdProgress,
                          captureID: camera.lastCaptureID) {
                if showingFormat { closeFormat() }
                camera.shutterPressed()
            }
            .disabled(camera.interruptionMessage != nil)

            Spacer()

            GlassIconButton(symbol: "arrow.triangle.2.circlepath", size: 52) {
                camera.flipCamera()
            }
            .rotationEffect(iconAngle)
            .accessibilityLabel("Switch camera")
            #if os(macOS)
            .opacity(camera.cameras.count > 1 ? 1 : 0)
            .disabled(camera.cameras.count < 2)
            #endif
        }
    }

    private var holdProgress: Double {
        guard camera.smartShotState == .armed, case .holding(let p) = camera.readiness.phase else { return 0 }
        return p
    }
}

/// The yellow square the native camera shows where you tap to focus.
private struct FocusSquare: View {
    @State private var settled = false
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .strokeBorder(.yellow, lineWidth: 1.2)
            .frame(width: 76, height: 76)
            .scaleEffect(settled ? 1 : 1.4)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .task {
                withAnimation(.spring(duration: 0.3)) { settled = true }
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.4)) { visible = false }
            }
    }
}

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Camera Access Needed")
                .font(.title3.weight(.semibold))
            Text("Allow SmartShot to use the camera in Settings.")
                .foregroundStyle(.secondary)
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
            .foregroundStyle(.black)
            #else
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                    NSWorkspace.shared.open(url)
                }
            }
            #endif
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

#if os(iOS)
import UIKit

/// Tracks how the phone is held, so icons can turn while the portrait layout stays fixed.
@MainActor
@Observable
final class DeviceOrientation {
    var iconAngle: Angle = .zero
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func update() {
        switch UIDevice.current.orientation {
        case .landscapeLeft: iconAngle = .degrees(90)
        case .landscapeRight: iconAngle = .degrees(-90)
        case .portrait: iconAngle = .zero
        default: break // Face up/down and upside down keep the last angle.
        }
    }
}
#endif

extension View {
    /// The iOS 18 zoom transition, where available.
    @ViewBuilder
    func zoomTransition(sourceID: String, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func zoomTransitionSource(id: String, in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
