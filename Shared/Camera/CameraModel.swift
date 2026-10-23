@preconcurrency import AVFoundation
import ImageIO
import Photos
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

enum FlashSetting: CaseIterable {
    case auto, on, off

    var symbol: String {
        switch self {
        case .auto: "bolt.badge.automatic.fill"
        case .on: "bolt.fill"
        case .off: "bolt.slash.fill"
        }
    }

    var avMode: AVCaptureDevice.FlashMode {
        switch self {
        case .auto: .auto
        case .on: .on
        case .off: .off
        }
    }

    var next: FlashSetting {
        switch self {
        case .auto: .on
        case .on: .off
        case .off: .auto
        }
    }
}

/// A zoom button: the factor shown to the user and the device zoom factor it maps to.
struct ZoomStop: Identifiable, Equatable {
    let display: CGFloat
    let deviceFactor: CGFloat
    var id: CGFloat { display }

    var label: String {
        if display < 1 { return String(format: ".%d", Int((display * 10).rounded())) }
        return display.rounded() == display ? "\(Int(display))" : String(format: "%.1f", display)
    }
}

/// The file format photos are saved in, like the native camera's Format setting.
enum PhotoFormat: String, CaseIterable, Identifiable {
    case heif = "HEIF"
    /// Only where HEIF isn't available.
    case jpeg = "JPEG"
    /// Apple ProRAW (DNG), on devices that support it.
    case raw = "RAW"
    var id: String { rawValue }
}

/// A photo size the current camera can take.
struct PhotoResolution: Identifiable, Equatable {
    let width: Int32
    let height: Int32
    var id: Int { megapixels }
    var dimensions: CMVideoDimensions { CMVideoDimensions(width: width, height: height) }
    var pixels: Int { Int(width) * Int(height) }

    /// Rounded down, like the native camera's labels (8064×6048 is "48", not "49").
    var megapixels: Int { max(1, Int(Double(width) * Double(height) / 1_000_000)) }
}

/// SmartShot's state while it's waiting to take the shot.
enum SmartShotState: Equatable {
    /// Shows face feedback and waits for the shutter.
    case idle
    /// Running: a photo is taken every time everyone is ready, until the shutter is pressed again.
    case armed
    /// Back camera only: waiting for the person who pressed the shutter to step into the shot.
    case waitingForPhotographer
}

@MainActor
@Observable
final class CameraModel: NSObject {
    // MARK: UI state
    var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    var flash: FlashSetting = .off
    var position: AVCaptureDevice.Position = .back
    var smartShotState: SmartShotState = .idle
    /// Photos taken since SmartShot was started.
    var smartShotCount = 0
    var readiness = ReadinessSnapshot.empty
    var zoomStops: [ZoomStop] = []
    var displayZoom: CGFloat = 1
    var hasFlash = false
    var photoFormat: PhotoFormat = PhotoFormat(rawValue: UserDefaults.standard.string(forKey: "photoFormat") ?? "") ?? .heif
    var availableFormats: [PhotoFormat] = [.heif]
    var resolutions: [PhotoResolution] = []
    var resolution: PhotoResolution?
    var lastImage: PlatformImage?
    var lastCaptureID = 0
    var isCapturing = false
    /// Width / height of the frames the viewfinder shows.
    var frameAspect: CGFloat = 3.0 / 4.0
    var cameras: [AVCaptureDevice] = []
    var currentCameraID: String?
    var errorMessage: String?
    /// Shown over the viewfinder while another app (FaceTime, a call, Split View) has the camera.
    var interruptionMessage: String?
    /// Bumped on every tap-to-focus so the focus square animates again.
    var focusPoint: CGPoint?
    var focusID = 0

    var smartShotRunning: Bool { smartShotState == .armed || smartShotState == .waitingForPhotographer }

    // MARK: Capture objects
    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "smartshot.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "smartshot.video", qos: .userInitiated)
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoDataOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private var videoInput: AVCaptureDeviceInput?
    @ObservationIgnored private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored nonisolated(unsafe) private let detector = ReadinessDetector()
    @ObservationIgnored private var armedAt: Date?
    @ObservationIgnored private var armedHeadCount = 0
    @ObservationIgnored private var lastShotAt: Date?
    /// After a shot, wait for a new moment (someone moves or a few seconds pass) before shooting again.
    @ObservationIgnored private var needsNewMoment = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var photoDelegates: [Int64: PhotoCaptureDelegate] = [:]

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        observeSession()
    }

    /// Recovers from the things that stop a camera: other apps taking it, media server resets,
    /// and (on the Mac) cameras being plugged in or removed.
    private func observeSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopSmartShot()
                #if os(iOS)
                let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
                    .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
                switch reason {
                case .videoDeviceNotAvailableWithMultipleForegroundApps:
                    self.interruptionMessage = "Camera not available in Split View"
                case .videoDeviceNotAvailableDueToSystemPressure:
                    self.interruptionMessage = "Camera paused to cool down"
                default:
                    self.interruptionMessage = "Camera in use by another app"
                }
                #else
                self.interruptionMessage = "Camera in use by another app"
                #endif
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptionMessage = nil }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] _ in
            // Media services were reset or the session failed: start it again.
            MainActor.assumeIsolated {
                guard let self else { return }
                let session = self.session
                self.sessionQueue.async { if !session.isRunning { session.startRunning() } }
            }
        })
        #if os(iOS)
        observers.append(center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeContinuousFocus() }
        })
        #endif
        #if os(macOS)
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshCameraList()
                    // If the camera in use went away, switch to another one.
                    if let device = note.object as? AVCaptureDevice, device.uniqueID == self.currentCameraID,
                       name == AVCaptureDevice.wasDisconnectedNotification {
                        self.stopSmartShot()
                        Task { await self.configureSession(device: self.cameras.first) }
                    } else if self.currentCameraID == nil, let first = self.cameras.first {
                        Task { await self.configureSession(device: first) }
                    }
                }
            })
        }
        #endif
    }

    // MARK: - Lifecycle

    #if DEBUG
    /// Fills the UI with a staged moment for screenshots instead of starting the camera.
    func enterDemo(_ scene: String) {
        authorization = .authorized
        hasFlash = true
        flash = .off
        frameAspect = 3.0 / 4.0
        zoomStops = [ZoomStop(display: 0.5, deviceFactor: 1), ZoomStop(display: 1, deviceFactor: 2),
                     ZoomStop(display: 2, deviceFactor: 4), ZoomStop(display: 3, deviceFactor: 6)]
        displayZoom = 1
        availableFormats = [.heif, .raw]
        resolutions = [PhotoResolution(width: 4032, height: 3024), PhotoResolution(width: 8064, height: 6048)]
        resolution = resolutions.first
        let renderer = ImageRenderer(content: DemoScene().frame(width: 240, height: 320))
        renderer.scale = 2
        #if os(iOS)
        lastImage = renderer.uiImage
        #else
        lastImage = renderer.nsImage
        #endif
        let boxes = DemoScene.faceBoxes(aspect: frameAspect)
        var faces = boxes.enumerated().map { FaceStatus(id: $0.offset, box: $0.element, eyesOpen: true, facingCamera: true, still: true) }
        switch scene {
        case "waiting":
            faces[1].facingCamera = false
            readiness = ReadinessSnapshot(faces: faces, phase: .waiting)
            smartShotState = .armed
        case "posing":
            readiness = ReadinessSnapshot(faces: faces, phase: .holding(0.35))
            smartShotState = .armed
            smartShotCount = 6
        case "format":
            readiness = ReadinessSnapshot(faces: faces, phase: .holding(0))
            smartShotState = .idle
        default:
            readiness = ReadinessSnapshot(faces: faces, phase: .holding(0.72))
            smartShotState = .armed
            smartShotCount = 2
        }
    }
    #endif

    func start() async {
        #if DEBUG
        if DemoMode.scene != nil { return }
        #endif
        if authorization == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
        }
        guard authorization == .authorized else { return }
        if !configured {
            configured = true
            refreshCameraList()
            await configureSession(device: defaultDevice(for: position))
            // The saved resolution is only known now; 48MP may need the main camera instead.
            if let preferred = defaultDevice(for: position), preferred.uniqueID != currentCameraID {
                await configureSession(device: preferred)
            }
        }
        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
        if lastImage == nil { await loadLatestLibraryPhoto() }
    }

    /// Like the native camera, the thumbnail shows the newest photo in the library.
    /// Only when Photos access was already given, so launching never asks for it.
    private func loadLatestLibraryPhoto(replacing: Bool = false) async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject else { return }
        let image: PlatformImage? = await withCheckedContinuation { continuation in
            let request = PHImageRequestOptions()
            request.deliveryMode = .highQualityFormat
            request.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 200, height: 200),
                                                  contentMode: .aspectFill, options: request) { image, _ in
                continuation.resume(returning: image)
            }
        }
        if lastImage == nil || replacing { lastImage = image }
    }

    /// The photo viewer covers the camera, so stop shooting and free the camera, like the native app.
    func pause() {
        stopSmartShot()
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    func resume() {
        guard authorization == .authorized, configured else { return }
        let session = session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
        // The newest photo may have been deleted or edited in the viewer.
        Task { await loadLatestLibraryPhoto(replacing: true) }
    }

    func stop() {
        stopSmartShot()
        let session = session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    // MARK: - Devices

    private func refreshCameraList() {
        #if os(macOS)
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        #endif
    }

    private func defaultDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        #if os(iOS)
        if position == .back { return backDevice(forDisplayZoom: 1) }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera],
                                                mediaType: .video, position: .front).devices.first
        #else
        return AVCaptureDevice.default(for: .video) ?? cameras.first
        #endif
    }

    #if os(iOS)
    /// The multi-lens back camera that switches between .5×, 1× and telephoto.
    private var backMultiCamera: AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera],
                                         mediaType: .video, position: .back).devices.first
    }

    /// The main (1×) back camera on its own. On some iPhones (like the 14 Pro) only this
    /// one can take 48MP photos; the multi-lens camera tops out at 12MP.
    private var backMainCamera: AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    /// Like the native camera in 48MP mode: 1× and 2× shoot from the main camera at full
    /// resolution, .5× and telephoto from the multi-lens camera at its own (smaller) size.
    private func backDevice(forDisplayZoom zoom: CGFloat) -> AVCaptureDevice? {
        guard let multi = backMultiCamera else { return backMainCamera }
        guard let main = backMainCamera, let resolution, zoom >= 1, zoom < 2.5,
              Self.maxPhotoPixels(of: multi) < resolution.pixels,
              Self.maxPhotoPixels(of: main) >= resolution.pixels else { return multi }
        return main
    }

    nonisolated private static func maxPhotoPixels(of device: AVCaptureDevice) -> Int {
        bestPhotoFormat(of: device)?.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
    }
    #endif

    private func configureSession(device: AVCaptureDevice?) async {
        guard let device else {
            interruptionMessage = "No Camera Available"
            return
        }
        let session = session
        let photoOutput = photoOutput
        let videoDataOutput = videoDataOutput
        let oldInput = videoInput

        let input: AVCaptureDeviceInput? = await withCheckedContinuation { continuation in
            sessionQueue.async { [videoQueue] in
                session.beginConfiguration()
                defer { session.commitConfiguration() }

                if let oldInput { session.removeInput(oldInput) }
                guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                    if let oldInput, session.canAddInput(oldInput) { session.addInput(oldInput) }
                    continuation.resume(returning: nil)
                    return
                }
                session.addInput(input)
                #if os(iOS)
                if !Self.useBestPhotoFormat(on: device), session.canSetSessionPreset(.photo) {
                    session.sessionPreset = .photo
                }
                #else
                if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
                #endif

                if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) {
                    session.addOutput(photoOutput)
                    photoOutput.maxPhotoQualityPrioritization = .quality
                }
                if !session.outputs.contains(videoDataOutput), session.canAddOutput(videoDataOutput) {
                    videoDataOutput.alwaysDiscardsLateVideoFrames = true
                    videoDataOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    ]
                    videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
                    session.addOutput(videoDataOutput)
                }
                #if os(iOS)
                // Face analysis only needs screen-sized frames, even when the camera streams 12MP.
                videoDataOutput.automaticallyConfiguresOutputBufferDimensions = false
                videoDataOutput.deliversPreviewSizedOutputBuffers = true
                #endif

                // Allow the largest photos this camera can take; each shot then asks for the chosen size.
                let sizes = device.activeFormat.supportedMaxPhotoDimensions
                if let largest = sizes.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
                    photoOutput.maxPhotoDimensions = largest
                }
                continuation.resume(returning: input)
            }
        }
        updatePhotoOptions(for: device)

        guard let input else {
            errorMessage = "Couldn't open \(device.localizedName)."
            return
        }
        videoInput = input
        currentCameraID = device.uniqueID
        #if os(iOS)
        position = device.position
        #endif
        hasFlash = device.hasFlash
        errorMessage = nil
        if interruptionMessage == "No Camera Available" { interruptionMessage = nil }
        setUpZoomStops(for: device)
        setUpRotation(for: device)
        resetDetector()
        readiness = .empty
    }

    private func setUpRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
        let mirrored = previewLayer.connection?.isVideoMirrored ?? false
        let dataOutput = videoDataOutput
        let dims = device.activeFormat.formatDescription.dimensions
        sessionQueue.async {
            // Leave analysis frames as the sensor delivers them; Vision turns them to match the viewfinder.
            guard let connection = dataOutput.connection(with: .video) else { return }
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }
        let orientation = Self.visionOrientation(angle: angle, mirrored: mirrored)
        let detector = detector
        videoQueue.async { detector.orientation = orientation }
        let rotated = Int(angle) % 180 != 0
        let w = CGFloat(rotated ? dims.height : dims.width)
        let h = CGFloat(rotated ? dims.width : dims.height)
        if w > 0, h > 0 { frameAspect = w / h }
    }

    nonisolated private static func visionOrientation(angle: CGFloat, mirrored: Bool) -> CGImagePropertyOrientation {
        switch (Int(angle.rounded()) % 360 + 360) % 360 {
        case 90: mirrored ? .leftMirrored : .right
        case 180: mirrored ? .downMirrored : .down
        case 270: mirrored ? .rightMirrored : .left
        default: mirrored ? .upMirrored : .up
        }
    }

    #if os(iOS)
    /// The 4:3 format that can take the biggest photos this camera supports. Among formats
    /// that tie, the smallest stream wins, since the viewfinder and face analysis don't need more.
    nonisolated private static func bestPhotoFormat(of device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        func photoPixels(_ format: AVCaptureDevice.Format) -> Int {
            format.supportedMaxPhotoDimensions.map { Int($0.width) * Int($0.height) }.max() ?? 0
        }
        let yuv: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        let candidates = device.formats.filter { format in
            let d = format.formatDescription.dimensions
            return yuv.contains(CMFormatDescriptionGetMediaSubType(format.formatDescription))
                && Int(d.width) * 3 == Int(d.height) * 4
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
        }
        let bestPhoto = candidates.map(photoPixels).max() ?? 0
        guard bestPhoto >= 12_000_000 else { return nil }
        return candidates.filter { photoPixels($0) == bestPhoto }.min { a, b in
            if a.isHighestPhotoQualitySupported != b.isHighestPhotoQualitySupported { return a.isHighestPhotoQualitySupported }
            let fullA = CMFormatDescriptionGetMediaSubType(a.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            let fullB = CMFormatDescriptionGetMediaSubType(b.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            if fullA != fullB { return fullA }
            return a.formatDescription.dimensions.width < b.formatDescription.dimensions.width
        }
    }

    /// Returns false if there's no suitable format and the `.photo` preset should be used.
    nonisolated private static func useBestPhotoFormat(on device: AVCaptureDevice) -> Bool {
        guard let best = bestPhotoFormat(of: device), (try? device.lockForConfiguration()) != nil else { return false }
        device.activeFormat = best
        device.unlockForConfiguration()
        return true
    }
    #endif

    // MARK: - Format and resolution

    private func updatePhotoOptions(for device: AVCaptureDevice) {
        // Offer every size the back cameras can take between them, not just the current lens.
        var sizes = device.activeFormat.supportedMaxPhotoDimensions
        #if os(iOS)
        if device.position == .back {
            for camera in [backMultiCamera, backMainCamera].compactMap({ $0 }) {
                sizes += Self.bestPhotoFormat(of: camera)?.supportedMaxPhotoDimensions ?? []
            }
        }
        #endif
        var byMegapixels: [Int: PhotoResolution] = [:]
        for d in sizes {
            let r = PhotoResolution(width: d.width, height: d.height)
            if let existing = byMegapixels[r.megapixels], Int(existing.width) * Int(existing.height) >= Int(d.width) * Int(d.height) { continue }
            byMegapixels[r.megapixels] = r
        }
        // Like the native camera, don't offer the small sizes some formats list.
        let all = byMegapixels.values.sorted { $0.megapixels < $1.megapixels }
        let large = all.filter { $0.megapixels >= 10 && Int($0.width) * 3 == Int($0.height) * 4 }
        resolutions = large.isEmpty ? Array(all.suffix(1)) : large

        // Keep the saved choice when this camera has it; otherwise use the native default:
        // the biggest size up to 24MP (48MP is opt-in, as in the native camera).
        let saved = UserDefaults.standard.integer(forKey: "photoMegapixels")
        resolution = resolutions.first { $0.megapixels == saved }
            ?? resolutions.last { $0.megapixels <= 24 }
            ?? resolutions.first

        var formats: [PhotoFormat] = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? [.heif] : [.jpeg]
        #if os(iOS)
        if photoOutput.isAppleProRAWSupported { formats.append(.raw) }
        #endif
        availableFormats = formats
        if !formats.contains(photoFormat) { photoFormat = formats[0] }
        applyRAWSetting()
    }

    func selectFormat(_ format: PhotoFormat) {
        guard availableFormats.contains(format) else { return }
        photoFormat = format
        UserDefaults.standard.set(format.rawValue, forKey: "photoFormat")
        applyRAWSetting()
    }

    func selectResolution(_ choice: PhotoResolution) {
        resolution = choice
        UserDefaults.standard.set(choice.megapixels, forKey: "photoMegapixels")
        #if os(iOS)
        // 48MP may need the main camera on its own (or the multi-lens camera back for 12MP).
        if position == .back, let target = backDevice(forDisplayZoom: displayZoom), target.uniqueID != currentCameraID {
            Task { await configureSession(device: target) }
        }
        #endif
    }

    private func applyRAWSetting() {
        #if os(iOS)
        let output = photoOutput
        let enable = photoFormat == .raw
        sessionQueue.async {
            if output.isAppleProRAWSupported, output.isAppleProRAWEnabled != enable {
                output.isAppleProRAWEnabled = enable
            }
        }
        #endif
    }

    // MARK: - Camera switching

    func flipCamera() {
        stopSmartShot()
        #if os(iOS)
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        displayZoom = 1
        Task { await configureSession(device: defaultDevice(for: newPosition)) }
        #else
        refreshCameraList()
        guard cameras.count > 1, let index = cameras.firstIndex(where: { $0.uniqueID == currentCameraID }) else { return }
        Task { await configureSession(device: cameras[(index + 1) % cameras.count]) }
        #endif
    }

    func selectCamera(_ device: AVCaptureDevice) {
        guard device.uniqueID != currentCameraID else { return }
        stopSmartShot()
        Task { await configureSession(device: device) }
    }

    // MARK: - Zoom

    #if os(iOS)
    /// Converts device zoom factors to the numbers the native camera shows (where the
    /// ultra wide is .5×).
    private func displayMultiplier(of device: AVCaptureDevice) -> CGFloat {
        if #available(iOS 18.0, *) { return device.displayVideoZoomFactorMultiplier }
        return device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera } ? 0.5 : 1
    }
    #endif

    /// The zoom buttons always come from the multi-lens camera, even while the main camera
    /// is used on its own for 48MP, so .5× and telephoto stay one tap away.
    private func setUpZoomStops(for device: AVCaptureDevice) {
        #if os(iOS)
        guard device.position == .back, let source = backMultiCamera ?? backMainCamera else {
            zoomStops = []
            displayZoom = 1
            applyZoom(animated: false)
            return
        }
        let multiplier = displayMultiplier(of: source)
        let factors: [CGFloat] = [1] + source.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        var stops = factors.map { ZoomStop(display: $0 * multiplier, deviceFactor: $0) }
        // The native camera always offers a 2× crop off the main sensor.
        if !stops.contains(where: { $0.display == 2 }), source.maxAvailableVideoZoomFactor >= 2 / multiplier {
            stops.append(ZoomStop(display: 2, deviceFactor: 2 / multiplier))
        }
        zoomStops = stops.sorted { $0.display < $1.display }
        applyZoom(animated: false)
        #else
        zoomStops = []
        displayZoom = 1
        #endif
    }

    /// Sets the current camera to `displayZoom`.
    private func applyZoom(animated: Bool) {
        #if os(iOS)
        guard let device = videoInput?.device else { return }
        setDeviceZoom(displayZoom / displayMultiplier(of: device), animated: animated)
        #endif
    }

    func selectZoom(_ stop: ZoomStop) {
        displayZoom = stop.display
        #if os(iOS)
        if position == .back, let target = backDevice(forDisplayZoom: stop.display), target.uniqueID != currentCameraID {
            Task { await configureSession(device: target) }
            return
        }
        #endif
        applyZoom(animated: true)
    }

    /// Pinch zoom, in display units (what the zoom buttons show).
    func setDisplayZoom(_ value: CGFloat) {
        #if os(iOS)
        guard let device = videoInput?.device, !zoomStops.isEmpty else { return }
        let m = displayMultiplier(of: device)
        let minDisplay = device.minAvailableVideoZoomFactor * m
        let maxDisplay = min(device.maxAvailableVideoZoomFactor, 15 / m) * m
        displayZoom = min(max(value, minDisplay), maxDisplay)
        applyZoom(animated: false)
        #endif
    }

    private func setDeviceZoom(_ factor: CGFloat, animated: Bool) {
        #if os(iOS)
        guard let device = videoInput?.device else { return }
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        }
        #endif
    }

    // MARK: - Focus

    /// Tap to focus and expose, like the native camera. `point` is in the viewfinder,
    /// normalized with a top-left origin.
    func focus(at point: CGPoint) {
        guard let device = videoInput?.device else { return }
        focusPoint = point
        focusID += 1
        let devicePoint = previewLayer.captureDevicePointConverted(
            fromLayerPoint: CGPoint(x: point.x * previewLayer.bounds.width, y: point.y * previewLayer.bounds.height))
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            #if os(iOS)
            // Go back to continuous focus when the scene changes, as the native camera does.
            device.isSubjectAreaChangeMonitoringEnabled = true
            #endif
            device.unlockForConfiguration()
        }
    }

    /// After a tap-to-focus, once the scene changes, focus and exposure follow the whole frame again.
    private func resumeContinuousFocus() {
        guard let device = videoInput?.device else { return }
        focusPoint = nil
        sessionQueue.async {
            guard (try? device.lockForConfiguration()) != nil else { return }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            #if os(iOS)
            device.isSubjectAreaChangeMonitoringEnabled = false
            #endif
            device.unlockForConfiguration()
        }
    }

    // MARK: - SmartShot

    /// The detector lives on the video queue; touching it from here would race with frame analysis.
    private func resetDetector() {
        let detector = detector
        videoQueue.async { detector.reset() }
    }

    private func rearmDetector() {
        let detector = detector
        videoQueue.async { detector.rearm() }
    }

    /// The shutter button starts and stops continuous SmartShot.
    func shutterPressed() {
        if smartShotRunning {
            stopSmartShot()
        } else {
            startSmartShot()
        }
    }

    private func startSmartShot() {
        armedAt = Date()
        armedHeadCount = readiness.total
        lastShotAt = nil
        needsNewMoment = false
        smartShotCount = 0
        rearmDetector()
        #if os(iOS)
        // With the back camera, whoever pressed the shutter is behind the phone. Wait for them.
        smartShotState = position == .back ? .waitingForPhotographer : .armed
        #else
        smartShotState = .armed
        #endif
    }

    func stopSmartShot() {
        armedAt = nil
        if smartShotRunning { smartShotState = .idle }
    }

    private func handle(_ snapshot: ReadinessSnapshot) {
        readiness = snapshot
        guard let armedAt else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(armedAt)

        if smartShotState == .waitingForPhotographer {
            // Give up waiting after a while; maybe they're not joining the photo.
            if snapshot.total > armedHeadCount || elapsed > 10 || armedHeadCount == 0 && snapshot.total > 0 && elapsed > 3 {
                smartShotState = .armed
                rearmDetector()
            }
            return
        }
        guard smartShotState == .armed else { return }

        if needsNewMoment {
            let sinceShot = lastShotAt.map { now.timeIntervalSince($0) } ?? .infinity
            switch snapshot.phase {
            case .noPeople, .gathering, .waiting:
                // Someone moved or changed pose: the next "everyone ready" is a new photo.
                needsNewMoment = false
            case .holding:
                // Everyone is still frozen in the same pose; take another after a few seconds anyway.
                if sinceShot > 4 {
                    needsNewMoment = false
                    rearmDetector()
                }
            }
            return
        }

        // A short grace period so the first shot doesn't fire the instant the button is tapped.
        guard snapshot.shouldCapture, elapsed > 1.0, !isCapturing else { return }
        if let lastShotAt, now.timeIntervalSince(lastShotAt) < 1.5 { return }

        lastShotAt = now
        needsNewMoment = true
        smartShotCount += 1
        rearmDetector()
        capturePhoto(signalWithLight: true)
    }

    // MARK: - Photo

    /// `signalWithLight`: after the exposure, blink the back camera's light so the group in front
    /// of the phone (who can't see the screen) knows a photo was just taken, like Smart Take.
    func capturePhoto(signalWithLight: Bool = false) {
        guard !isCapturing else { return }
        isCapturing = true
        var settings: AVCapturePhotoSettings
        var isRAW = false
        switch photoFormat {
        case .heif where photoOutput.availablePhotoCodecTypes.contains(.hevc):
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        case .raw:
            #if os(iOS)
            if photoOutput.isAppleProRAWEnabled,
               let raw = photoOutput.availableRawPhotoPixelFormatTypes.first(where: {
                   AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
               }) {
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                isRAW = true
            } else {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            }
            #else
            settings = AVCapturePhotoSettings()
            #endif
        default:
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        }
        if hasFlash, photoOutput.supportedFlashModes.contains(flash.avMode) {
            settings.flashMode = flash.avMode
        }
        // The chosen size, or the closest smaller one this lens can take (.5× and telephoto
        // take 12MP even in 48MP mode, like the native camera).
        if let resolution, let device = videoInput?.device,
           let size = device.activeFormat.supportedMaxPhotoDimensions
               .filter({ Int($0.width) * Int($0.height) <= resolution.pixels })
               .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            settings.maxPhotoDimensions = size
        }
        // Full processing (Deep Fusion, Smart HDR), the same as the native camera.
        if !isRAW { settings.photoQualityPrioritization = photoOutput.maxPhotoQualityPrioritization }

        if let connection = photoOutput.connection(with: .video) {
            // Save the photo the way the viewfinder shows it: selfies come out mirrored, as you saw
            // yourself, instead of flipped in Photos.
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = previewLayer.connection?.isVideoMirrored ?? false
            }
            if let coordinator = rotationCoordinator {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            }
        }

        let id = settings.uniqueID
        var lightDevice: AVCaptureDevice?
        #if os(iOS)
        if signalWithLight, position == .back, settings.flashMode == .off,
           let device = videoInput?.device, device.hasTorch {
            lightDevice = device
        }
        #endif
        let delegate = PhotoCaptureDelegate(onCaptured: { [weak self] in
            guard let lightDevice else { return }
            self?.blinkLight(on: lightDevice)
        }) { [weak self] data in
            // Make the thumbnail here, off the main thread: decoding a 48MP photo there stutters.
            let thumbnail = data.flatMap { Self.thumbnail(from: $0, maxPixels: 240) }
            Task { @MainActor in self?.photoFinished(id: id, data: data, thumbnail: thumbnail, isRAW: isRAW) }
        }
        photoDelegates[id] = delegate
        lastCaptureID += 1
        let output = photoOutput
        sessionQueue.async { output.capturePhoto(with: settings, delegate: delegate) }
    }

    /// A soft glow of the camera light: a dim indicator, not a flash. It fades up to about 10%
    /// and back over roughly a third of a second. Runs on the session queue after the photo has
    /// been exposed, so it never shows up in the picture.
    nonisolated private func blinkLight(on device: AVCaptureDevice) {
        #if os(iOS)
        let levels: [Float] = [0.03, 0.06, 0.1, 0.1, 0.06, 0.03]
        let step = 0.055
        for (i, level) in levels.enumerated() {
            sessionQueue.asyncAfter(deadline: .now() + step * Double(i)) {
                guard device.isTorchAvailable, (try? device.lockForConfiguration()) != nil else { return }
                try? device.setTorchModeOn(level: level)
                device.unlockForConfiguration()
            }
        }
        sessionQueue.asyncAfter(deadline: .now() + step * Double(levels.count)) {
            guard (try? device.lockForConfiguration()) != nil else { return }
            if device.torchMode != .off { device.torchMode = .off }
            device.unlockForConfiguration()
        }
        #endif
    }

    private func photoFinished(id: Int64, data: Data?, thumbnail: PlatformImage?, isRAW: Bool) {
        photoDelegates[id] = nil
        isCapturing = false
        guard let data else {
            errorMessage = "Couldn't take the photo."
            return
        }
        if let thumbnail { lastImage = thumbnail }
        Task { await MediaSaver.savePhoto(data, isRAW: isRAW) }
    }

    nonisolated static func thumbnail(from data: Data, maxPixels: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
              ] as CFDictionary) else { return nil }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

// MARK: - Frame analysis

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let snapshot = detector.process(pixelBuffer, time: time) else { return }
        Task { @MainActor in self.handle(snapshot) }
    }
}

// MARK: - Photo delegate

/// Reports exactly once, even when a capture fails before any photo is processed.
private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onCaptured: () -> Void
    private let completion: (Data?) -> Void
    private var data: Data?

    init(onCaptured: @escaping () -> Void = {}, completion: @escaping (Data?) -> Void) {
        self.onCaptured = onCaptured
        self.completion = completion
    }

    /// The exposure is done (the shutter sound plays now); the photo is still being processed.
    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onCaptured()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil { data = photo.fileDataRepresentation() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        completion(data)
    }
}
