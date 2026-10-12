import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// The edit settings, saved with the photo so the edit can be reopened or reverted in Photos.
struct PhotoAdjustments: Codable, Equatable {
    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var warmth: Double = 0
    /// Quarter turns clockwise.
    var rotation: Int = 0
    /// Degrees, -45...45, clockwise.
    var straighten: Double = 0
    var flipped = false
    /// Normalized crop (top-left origin) of the rotated, flipped, straightened photo. nil keeps it all.
    var crop: CGRect?

    static let formatIdentifier = "com.harkhowalia.smartshot.adjustments"
    static let formatVersion = "2"

    var isIdentity: Bool { self == PhotoAdjustments() }
    var hasGeometry: Bool { rotation % 4 != 0 || straighten != 0 || flipped || crop != nil }

    init() {}

    // Edits saved by version 1 have no straighten, flip or crop.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 0
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        straighten = try c.decodeIfPresent(Double.self, forKey: .straighten) ?? 0
        flipped = try c.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
    }

    /// Rotation, flip and straighten. Straightening zooms in just enough to hide the corners.
    func geometry(_ input: CIImage) -> CIImage {
        var image = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        let turns = ((rotation % 4) + 4) % 4
        if turns != 0 {
            image = image.oriented([.up, .right, .down, .left][turns])
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let w = image.extent.width, h = image.extent.height
        if flipped {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -w, y: 0))
        }
        if straighten != 0, w > 0, h > 0 {
            let theta = abs(straighten) * .pi / 180
            let cover = cos(theta) + sin(theta) * max(w / h, h / w)
            let transform = CGAffineTransform(translationX: w / 2, y: h / 2)
                .scaledBy(x: cover, y: cover)
                .rotated(by: -straighten * .pi / 180)
                .translatedBy(x: -w / 2, y: -h / 2)
            image = image.transformed(by: transform).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return image
    }

    func cropped(_ image: CIImage) -> CIImage {
        guard let crop else { return image }
        let e = image.extent
        let rect = CGRect(x: e.minX + crop.minX * e.width,
                          y: e.minY + (1 - crop.maxY) * e.height,
                          width: crop.width * e.width,
                          height: crop.height * e.height).integral
        let out = image.cropped(to: rect)
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
    }

    func color(_ input: CIImage) -> CIImage {
        var image = input
        if exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(exposure)
            image = f.outputImage ?? image
        }
        if contrast != 0 || saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.contrast = Float(1 + contrast * 0.5)
            f.saturation = Float(1 + saturation)
            image = f.outputImage ?? image
        }
        if warmth != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 - warmth * 2500, y: 0)
            image = f.outputImage ?? image
        }
        return image.cropped(to: input.extent)
    }

    func apply(to input: CIImage) -> CIImage {
        color(cropped(geometry(input)))
    }
}

/// A Photos-style editor: Adjust (light and color) and Crop (crop, aspect, rotate, flip, straighten).
struct PhotoEditor: View {
    let asset: PHAsset
    let done: () -> Void

    private enum Tool: String, CaseIterable { case adjust = "Adjust", crop = "Crop" }
    private enum Control: String, CaseIterable, Identifiable {
        case exposure = "Exposure", contrast = "Contrast", saturation = "Saturation", warmth = "Warmth"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .exposure: "plusminus.circle"
            case .contrast: "circle.lefthalf.filled"
            case .saturation: "drop.halffull"
            case .warmth: "thermometer.medium"
            }
        }
    }

    @State private var tool: Tool = .adjust
    @State private var control: Control = .exposure
    @State private var adjustments = PhotoAdjustments()
    @State private var loadedAdjustments = PhotoAdjustments()
    @State private var aspect: CropAspect = .freeform
    @State private var original: CIImage?
    @State private var preview: CGImage?
    @State private var input: PHContentEditingInput?
    @State private var hasSavedEdits = false
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmingDiscard = false
    @State private var renderTask: Task<Void, Never>?

    private let context = CIContext(options: [.cacheIntermediates: false])

    private var changed: Bool { adjustments != loadedAdjustments }

    var body: some View {
        VStack(spacing: 0) {
            header

            GeometryReader { geo in
                ZStack {
                    if let preview {
                        let frame = Self.fit(CGSize(width: preview.width, height: preview.height),
                                             in: geo.size.insetBy(tool == .crop ? 28 : 12))
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .frame(width: frame.width, height: frame.height)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        if tool == .crop {
                            CropOverlay(rect: cropBinding,
                                        imageFrame: CGRect(x: (geo.size.width - frame.width) / 2,
                                                           y: (geo.size.height - frame.height) / 2,
                                                           width: frame.width, height: frame.height),
                                        aspect: aspect.ratio(imageAspect: frame.width / frame.height))
                        }
                    } else if failure == nil {
                        ProgressView()
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }

            Group {
                switch tool {
                case .adjust: adjustControls
                case .crop: cropControls
                }
            }
            .frame(height: 150)

            HStack(spacing: 40) {
                ForEach(Tool.allCases, id: \.self) { t in
                    Button(t.rawValue.uppercased()) { tool = t }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .kerning(0.6)
                        .foregroundStyle(tool == t ? .yellow : .white.opacity(0.7))
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .disabled(saving)
        .task { await loadInput() }
        .onChange(of: adjustments) { renderPreview() }
        .onChange(of: tool) { renderPreview() }
        .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive, action: done)
            Button("Keep Editing", role: .cancel) {}
        }
        .alert(failure ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { if original == nil { done() } }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button("Cancel") {
                if changed { confirmingDiscard = true } else { done() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .keyboardShortcut(.cancelAction)

            Spacer()

            if changed || hasSavedEdits {
                Button("Revert", action: revert)
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button(action: save) {
                if saving { ProgressView().controlSize(.small).tint(.black) } else { Text("Done").bold() }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(changed ? Color.yellow : Color.yellow.opacity(0.4), in: Capsule())
            .disabled(input == nil || !changed)
            .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 16, weight: .medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Adjust

    private var adjustControls: some View {
        VStack(spacing: 14) {
            Text(control.rawValue.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.white.opacity(0.8))
            HStack(spacing: 18) {
                ForEach(Control.allCases) { c in
                    Button { control = c } label: {
                        ZStack {
                            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                            Circle()
                                .trim(from: 0, to: abs(value(c)))
                                .stroke(.yellow, lineWidth: 2)
                                .rotationEffect(.degrees(-90))
                                .scaleEffect(x: value(c) < 0 ? -1 : 1)
                            Image(systemName: c.symbol).font(.system(size: 17))
                        }
                        .foregroundStyle(control == c ? .yellow : .white)
                        .frame(width: 48, height: 48)
                        .background(control == c ? Color.white.opacity(0.12) : .clear, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.rawValue)
                }
            }
            CenterSlider(value: binding(control), range: -1...1)
                .frame(height: 36)
                .padding(.horizontal, 32)
        }
    }

    private func value(_ c: Control) -> Double {
        switch c {
        case .exposure: adjustments.exposure
        case .contrast: adjustments.contrast
        case .saturation: adjustments.saturation
        case .warmth: adjustments.warmth
        }
    }

    private func binding(_ c: Control) -> Binding<Double> {
        switch c {
        case .exposure: $adjustments.exposure
        case .contrast: $adjustments.contrast
        case .saturation: $adjustments.saturation
        case .warmth: $adjustments.warmth
        }
    }

    // MARK: - Crop

    private var cropBinding: Binding<CGRect> {
        Binding(get: { adjustments.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1) },
                set: { rect in
                    let full = abs(rect.minX) < 0.001 && abs(rect.minY) < 0.001
                        && abs(rect.width - 1) < 0.001 && abs(rect.height - 1) < 0.001
                    adjustments.crop = full ? nil : rect
                })
    }

    /// Width / height of the photo being cropped (after rotation).
    private var imageAspect: CGFloat {
        guard let preview, preview.height > 0 else { return 1 }
        return CGFloat(preview.width) / CGFloat(preview.height)
    }

    private var cropControls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 26) {
                Button {
                    adjustments.rotation -= 1
                    adjustments.crop = nil
                } label: { Image(systemName: "rotate.left") }
                .accessibilityLabel("Rotate")

                Button { adjustments.flipped.toggle() } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .accessibilityLabel("Flip")

                Menu {
                    ForEach(CropAspect.allCases) { option in
                        Button {
                            aspect = option
                            applyAspect()
                        } label: {
                            if option == aspect { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                        }
                    }
                } label: {
                    Image(systemName: "aspectratio")
                        .foregroundStyle(aspect == .freeform ? .white : .yellow)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Aspect ratio")

                if adjustments.hasGeometry {
                    Button("RESET") {
                        adjustments.rotation = 0
                        adjustments.straighten = 0
                        adjustments.flipped = false
                        adjustments.crop = nil
                        aspect = .freeform
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.yellow)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 22))
            .foregroundStyle(.white)

            VStack(spacing: 6) {
                Text("STRAIGHTEN  \(Int(adjustments.straighten.rounded()))°")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .kerning(0.6)
                    .foregroundStyle(.white.opacity(0.8))
                CenterSlider(value: $adjustments.straighten, range: -45...45, ticks: 18)
                    .frame(height: 36)
                    .padding(.horizontal, 32)
            }
        }
    }

    /// Fits the largest crop of the chosen shape inside the photo, centred on the current crop.
    private func applyAspect() {
        guard let ratio = aspect.ratio(imageAspect: imageAspect) else { return }
        let k = imageAspect
        var w: CGFloat = 1
        var h = w * k / ratio
        if h > 1 { h = 1; w = ratio / k }
        let current = adjustments.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let x = min(max(current.midX - w / 2, 0), 1 - w)
        let y = min(max(current.midY - h / 2, 0), 1 - h)
        cropBinding.wrappedValue = CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Rendering

    private static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let r = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * r, height: size.height * r)
    }

    /// Renders off the main thread; only the newest render is shown, so sliders stay smooth.
    private func renderPreview() {
        guard let original else { return }
        let adjustments = adjustments
        let showCrop = tool == .adjust
        let context = context
        renderTask?.cancel()
        renderTask = Task.detached(priority: .userInitiated) {
            let geometry = adjustments.geometry(original)
            let output = adjustments.color(showCrop ? adjustments.cropped(geometry) : geometry)
            let image = context.createCGImage(output, from: output.extent)
            guard !Task.isCancelled else { return }
            await MainActor.run { preview = image }
        }
    }

    // MARK: - Photos editing

    private func loadInput() async {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        // If the photo was last edited here, start from the original and reapply our settings.
        options.canHandleAdjustmentData = { data in
            data.formatIdentifier == PhotoAdjustments.formatIdentifier
        }
        let input: PHContentEditingInput? = await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, _ in continuation.resume(returning: input) }
        }
        let resources = PHAssetResource.assetResources(for: asset)
        hasSavedEdits = resources.contains { $0.type == .adjustmentData || $0.type == .fullSizePhoto }
        guard let input, let url = input.fullSizeImageURL,
              let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            failure = "This photo can't be edited."
            return
        }
        self.input = input
        if let data = input.adjustmentData,
           data.formatIdentifier == PhotoAdjustments.formatIdentifier,
           let saved = try? JSONDecoder().decode(PhotoAdjustments.self, from: data.data) {
            adjustments = saved
            loadedAdjustments = saved
        }
        // A screen-sized copy keeps every change instant; the full photo is used only when saving.
        let scale = min(1, 1800 / max(image.extent.width, image.extent.height))
        original = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        renderPreview()
    }

    /// Like Photos: a photo with saved edits goes back to its original; otherwise unsaved
    /// changes are cleared.
    private func revert() {
        guard hasSavedEdits else {
            adjustments = PhotoAdjustments()
            aspect = .freeform
            return
        }
        saving = true
        let asset = asset
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
                }
                done()
            } catch {
                saving = false
                failure = "Couldn't revert the photo."
            }
        }
    }

    private func save() {
        guard let input, let url = input.fullSizeImageURL else { return }
        saving = true
        let adjustments = adjustments
        let context = context
        let asset = asset
        Task.detached(priority: .userInitiated) {
            do {
                if adjustments.isIdentity {
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
                    }
                } else {
                    let output = try Self.render(adjustments, from: url, input: input, context: context)
                    try await PHPhotoLibrary.shared().performChanges {
                        PHAssetChangeRequest(for: asset).contentEditingOutput = output
                    }
                }
                await MainActor.run { done() }
            } catch {
                await MainActor.run {
                    saving = false
                    failure = "Couldn't save the edit."
                }
            }
        }
    }

    /// Renders the full-resolution edit as HEIF where Photos supports it (JPEG otherwise),
    /// keeping the camera metadata so Info still shows the lens, exposure and so on.
    nonisolated private static func render(_ adjustments: PhotoAdjustments, from url: URL,
                                           input: PHContentEditingInput, context: CIContext) throws -> PHContentEditingOutput {
        guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rendered = adjustments.apply(to: full)
        var properties = full.properties
        properties[kCGImagePropertyOrientation as String] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth as String)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight as String)
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            exif[kCGImagePropertyExifPixelXDimension as String] = Int(rendered.extent.width)
            exif[kCGImagePropertyExifPixelYDimension as String] = Int(rendered.extent.height)
            properties[kCGImagePropertyExifDictionary as String] = exif
        }
        let image = rendered.settingProperties(properties)
        let colorSpace = full.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!

        let output = PHContentEditingOutput(contentEditingInput: input)
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
        if output.supportedRenderedContentTypes.contains(.heic) {
            let target = try output.renderedContentURL(for: .heic)
            try context.writeHEIFRepresentation(of: image, to: target, format: .RGBA8, colorSpace: colorSpace, options: quality)
        } else {
            try context.writeJPEGRepresentation(of: image, to: output.renderedContentURL, colorSpace: colorSpace, options: quality)
        }
        output.adjustmentData = PHAdjustmentData(formatIdentifier: PhotoAdjustments.formatIdentifier,
                                                 formatVersion: PhotoAdjustments.formatVersion,
                                                 data: try JSONEncoder().encode(adjustments))
        return output
    }
}

private extension CGSize {
    func insetBy(_ amount: CGFloat) -> CGSize {
        CGSize(width: max(0, width - amount * 2), height: max(0, height - amount * 2))
    }
}

// MARK: - Aspect ratios

enum CropAspect: String, CaseIterable, Identifiable {
    case freeform, original, square, wide169, standard43, classic32, portrait54, story916
    var id: String { rawValue }

    var title: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .square: "Square"
        case .wide169: "16:9"
        case .standard43: "4:3"
        case .classic32: "3:2"
        case .portrait54: "5:4"
        case .story916: "9:16"
        }
    }

    /// Width / height, or nil for freeform.
    func ratio(imageAspect: CGFloat) -> CGFloat? {
        switch self {
        case .freeform: nil
        case .original: imageAspect
        case .square: 1
        case .wide169: 16.0 / 9.0
        case .standard43: 4.0 / 3.0
        case .classic32: 3.0 / 2.0
        case .portrait54: 4.0 / 5.0
        case .story916: 9.0 / 16.0
        }
    }
}

// MARK: - Crop box

/// The crop box: drag a corner or edge to resize, drag inside to move. The outside is dimmed
/// and a rule-of-thirds grid shows while dragging, like the Photos app.
private struct CropOverlay: View {
    @Binding var rect: CGRect
    let imageFrame: CGRect
    /// Width / height in pixels, or nil for freeform.
    let aspect: CGFloat?

    @State private var dragStart: CGRect?
    private let minSize: CGFloat = 0.1

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        var sx: CGFloat { [.topLeft, .bottomLeft, .left].contains(self) ? -1 : ([.top, .bottom].contains(self) ? 0 : 1) }
        var sy: CGFloat { [.topLeft, .top, .topRight].contains(self) ? -1 : ([.left, .right].contains(self) ? 0 : 1) }
        var isCorner: Bool { sx != 0 && sy != 0 }
    }

    private var box: CGRect {
        CGRect(x: imageFrame.minX + rect.minX * imageFrame.width,
               y: imageFrame.minY + rect.minY * imageFrame.height,
               width: rect.width * imageFrame.width,
               height: rect.height * imageFrame.height)
    }

    var body: some View {
        ZStack {
            // Dim everything outside the crop.
            Path { path in
                path.addRect(imageFrame)
                path.addRect(box)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .stroke(.white, lineWidth: 1)
                .frame(width: box.width, height: box.height)
                .position(x: box.midX, y: box.midY)
                .allowsHitTesting(false)

            if dragStart != nil {
                Path { path in
                    for i in 1...2 {
                        let x = box.minX + box.width * CGFloat(i) / 3
                        let y = box.minY + box.height * CGFloat(i) / 3
                        path.move(to: CGPoint(x: x, y: box.minY)); path.addLine(to: CGPoint(x: x, y: box.maxY))
                        path.move(to: CGPoint(x: box.minX, y: y)); path.addLine(to: CGPoint(x: box.maxX, y: y))
                    }
                }
                .stroke(.white.opacity(0.5), lineWidth: 0.5)
                .allowsHitTesting(false)
            }

            // Drag inside to move the crop.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: max(0, box.width - 44), height: max(0, box.height - 44))
                .position(x: box.midX, y: box.midY)
                .gesture(moveGesture)

            ForEach(Handle.allCases, id: \.self) { handle in
                handleView(handle)
            }
        }
    }

    @ViewBuilder private func handleView(_ handle: Handle) -> some View {
        let x = handle.sx < 0 ? box.minX : (handle.sx > 0 ? box.maxX : box.midX)
        let y = handle.sy < 0 ? box.minY : (handle.sy > 0 ? box.maxY : box.midY)
        let locked = aspect != nil && !handle.isCorner
        ZStack {
            if handle.isCorner {
                CornerMark(sx: handle.sx, sy: handle.sy)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .square))
                    .frame(width: 22, height: 22)
                    .offset(x: -handle.sx * 9, y: -handle.sy * 9)
            }
            Color.clear
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .position(x: x, y: y)
        .gesture(locked ? nil : resizeGesture(handle))
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let dx = value.translation.width / imageFrame.width
                let dy = value.translation.height / imageFrame.height
                rect.origin = CGPoint(x: min(max(start.minX + dx, 0), 1 - start.width),
                                      y: min(max(start.minY + dy, 0), 1 - start.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                rect = resized(start, handle: handle,
                               dx: value.translation.width / imageFrame.width,
                               dy: value.translation.height / imageFrame.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resized(_ s: CGRect, handle: Handle, dx: CGFloat, dy: CGFloat) -> CGRect {
        // The opposite corner or edge stays put.
        let anchorX = handle.sx < 0 ? s.maxX : s.minX
        let anchorY = handle.sy < 0 ? s.maxY : s.minY
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY

        if let aspect, handle.isCorner {
            // Normalized height for a normalized width at this shape.
            let k = imageFrame.width / imageFrame.height
            let hPerW = k / aspect
            let maxW = handle.sx < 0 ? anchorX : 1 - anchorX
            let maxH = handle.sy < 0 ? anchorY : 1 - anchorY
            var w = s.width + handle.sx * dx
            let fromHeight = (s.height + handle.sy * dy) / hPerW
            if abs(dy * imageFrame.height) > abs(dx * imageFrame.width) { w = fromHeight }
            w = min(w, maxW, maxH / hPerW)
            w = max(w, minSize, minSize / hPerW)
            let h = w * hPerW
            minX = handle.sx < 0 ? anchorX - w : anchorX
            maxX = minX + w
            minY = handle.sy < 0 ? anchorY - h : anchorY
            maxY = minY + h
        } else {
            if handle.sx < 0 { minX = min(max(s.minX + dx, 0), s.maxX - minSize) }
            if handle.sx > 0 { maxX = max(min(s.maxX + dx, 1), s.minX + minSize) }
            if handle.sy < 0 { minY = min(max(s.minY + dy, 0), s.maxY - minSize) }
            if handle.sy > 0 { maxY = max(min(s.maxY + dy, 1), s.minY + minSize) }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// An L-shaped corner handle pointing into the crop box.
private struct CornerMark: Shape {
    let sx: CGFloat
    let sy: CGFloat

    func path(in rect: CGRect) -> Path {
        let corner = CGPoint(x: sx < 0 ? rect.minX : rect.maxX, y: sy < 0 ? rect.minY : rect.maxY)
        var path = Path()
        path.move(to: CGPoint(x: corner.x - sx * rect.width, y: corner.y))
        path.addLine(to: corner)
        path.addLine(to: CGPoint(x: corner.x, y: corner.y - sy * rect.height))
        return path
    }
}

// MARK: - Slider

/// A slider that fills from its centre, like the Photos app's adjustment dials. Double-tap
/// to reset it to zero.
struct CenterSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var ticks = 20

    @State private var dragStartValue: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let span = range.upperBound - range.lowerBound
            let zeroX = width * CGFloat((0 - range.lowerBound) / span)
            let valueX = width * CGFloat((value - range.lowerBound) / span)
            ZStack(alignment: .leading) {
                // Ticks
                HStack(spacing: 0) {
                    ForEach(0...ticks, id: \.self) { i in
                        Rectangle()
                            .fill(.white.opacity(i == ticks / 2 ? 0.8 : 0.3))
                            .frame(width: 1, height: i == ticks / 2 ? 14 : 8)
                        if i < ticks { Spacer(minLength: 0) }
                    }
                }
                // Fill from the centre to the value
                Rectangle()
                    .fill(.yellow)
                    .frame(width: abs(valueX - zeroX), height: 3)
                    .offset(x: min(valueX, zeroX))
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(radius: 2)
                    .offset(x: valueX - 11)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStartValue ?? value
                        dragStartValue = start
                        let delta = Double(drag.translation.width / width) * span
                        var next = min(max(start + delta, range.lowerBound), range.upperBound)
                        // Snap to zero near the centre, with a haptic tick on iPhone.
                        if abs(next) < span * 0.015 { next = 0 }
                        value = next
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            .onTapGesture(count: 2) { withAnimation(.easeOut(duration: 0.2)) { value = 0 } }
            .sensoryFeedback(.selection, trigger: value == 0)
        }
        .accessibilityElement()
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 40
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}
