import SwiftUI

// MARK: - Liquid Glass with a material fallback for older systems

extension View {
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(tint?.opacity(0.6) ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
        }
    }
}

/// A round glass button for the top bar and the camera flip.
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = 38
    var tint: Color? = nil
    var foreground: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle(), tint: tint)
    }
}

// MARK: - Shutter

struct ShutterButton: View {
    let smartShot: SmartShotState
    /// 0...1 while everyone is holding still.
    let holdProgress: Double
    let captureID: Int
    let action: () -> Void

    private var running: Bool { smartShot == .armed || smartShot == .waitingForPhotographer }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 78, height: 78)

                if running {
                    if holdProgress > 0 {
                        // Everyone is ready: the ring fills while they hold still.
                        Circle()
                            .trim(from: 0, to: holdProgress)
                            .stroke(.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 74, height: 74)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.1), value: holdProgress)
                    } else {
                        // Watching: a short arc circles the shutter. Driven by the clock, so it
                        // never fights other animations.
                        TimelineView(.animation) { context in
                            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
                            Circle()
                                .trim(from: 0, to: 0.22)
                                .stroke(.yellow, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .frame(width: 74, height: 74)
                                .rotationEffect(.degrees(turn * 360 - 90))
                        }
                    }
                }

                // Running shows a stop square, like the native shutter while a timer counts down.
                RoundedRectangle(cornerRadius: running ? 7 : 32, style: .continuous)
                    .fill(.white)
                    .frame(width: running ? 28 : 64, height: running ? 28 : 64)
                    .overlay {
                        if smartShot == .idle {
                            SmartShotGlyph()
                                .foregroundStyle(.black.opacity(0.75))
                                .frame(width: 26, height: 26)
                        }
                    }
                    .animation(.spring(duration: 0.3), value: running)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
        }
        .buttonStyle(ShutterPressStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: captureID)
        .accessibilityLabel(running ? "Stop SmartShot" : "Start SmartShot")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The SmartShot icon: two people inside a viewfinder frame.
struct SmartShotGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                FaceBracket().stroke(style: StrokeStyle(lineWidth: max(1.2, s * 0.07), lineCap: .round))
                Image(systemName: "person.2.fill")
                    .font(.system(size: s * 0.42, weight: .semibold))
            }
        }
    }
}

// MARK: - Zoom

struct ZoomBar: View {
    let stops: [ZoomStop]
    let current: CGFloat
    var iconAngle: Angle = .zero
    let select: (ZoomStop) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(stops) { stop in
                let active = activeStop?.id == stop.id
                Button { select(stop) } label: {
                    Text(active ? activeLabel : stop.label)
                        .font(.system(size: active ? 13 : 12, weight: .semibold))
                        .foregroundStyle(active ? .yellow : .white)
                        .rotationEffect(iconAngle)
                        .frame(width: active ? 38 : 30, height: active ? 38 : 30)
                        .background(.black.opacity(active ? 0.45 : 0.3), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(stop.label)")
            }
        }
        .padding(4)
        .glass(in: Capsule())
        .animation(.spring(duration: 0.25), value: current)
    }

    private var activeStop: ZoomStop? {
        stops.last { $0.display <= current + 0.01 } ?? stops.first
    }

    private var activeLabel: String {
        let value = current.rounded(toPlaces: 1)
        if value < 1 { return String(format: ".%d×", Int((value * 10).rounded())) }
        return value.rounded() == value ? "\(Int(value))×" : String(format: "%.1f×", value)
    }
}

private extension CGFloat {
    func rounded(toPlaces places: Int) -> CGFloat {
        let p = pow(10, CGFloat(places))
        return (self * p).rounded() / p
    }
}

// MARK: - Thumbnail

struct ThumbnailButton: View {
    let image: PlatformImage?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    #if os(iOS)
                    Image(uiImage: image).resizable().scaledToFill()
                    #else
                    Image(nsImage: image).resizable().scaledToFill()
                    #endif
                } else {
                    Color.white.opacity(0.08)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25)))
            .id(image.map(ObjectIdentifier.init))
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .buttonStyle(.plain)
        .animation(.spring(duration: 0.35), value: image.map(ObjectIdentifier.init))
    }
}

// MARK: - Status

/// The yellow pill at the top of the viewfinder that tells everyone what SmartShot is waiting for.
struct SmartShotStatusPill: View {
    let state: SmartShotState
    let readiness: ReadinessSnapshot
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            SmartShotGlyph().frame(width: 14, height: 14)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .contentTransition(.numericText())
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow, in: Capsule())
        .animation(.easeOut(duration: 0.2), value: message)
    }

    private var message: String {
        let status = phaseMessage
        return count > 0 ? "\(status) · \(count) taken" : status
    }

    private var phaseMessage: String {
        if state == .waitingForPhotographer { return "Get in the shot" }
        switch readiness.phase {
        case .noPeople: return "Looking for people"
        case .gathering: return "Waiting for everyone"
        case .waiting:
            let total = readiness.total
            return total == 1 ? "Look at the camera" : "\(readiness.readyCount) of \(total) ready"
        case .holding: return "Hold still"
        }
    }
}

// MARK: - Format

/// The top-bar button showing the current format and resolution ("HEIF / 12"), like the native camera.
struct FormatButton: View {
    let format: PhotoFormat
    let resolution: PhotoResolution?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(format.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                if let resolution {
                    Text("\(resolution.megapixels)")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .frame(minWidth: 44, minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Format \(format.rawValue), \(resolution?.megapixels ?? 0) megapixels")
    }
}

/// The FORMAT panel that slides up over the bottom controls, like the native camera's.
struct FormatPanel: View {
    let formats: [PhotoFormat]
    let format: PhotoFormat
    let resolutions: [PhotoResolution]
    let resolution: PhotoResolution?
    let selectFormat: (PhotoFormat) -> Void
    let selectResolution: (PhotoResolution) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Text("FORMAT")
                    .font(.system(size: 15, weight: .medium))
                    .kerning(1)
                    .foregroundStyle(.white)
                HStack {
                    GlassIconButton(symbol: "xmark", size: 40, action: close)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 20) {
                if formats.count > 1 {
                    row("FORMAT") {
                        ForEach(formats) { f in
                            option(selected: f == format) {
                                Text(f.rawValue).font(.system(size: 17, weight: .semibold))
                            } action: { selectFormat(f) }
                        }
                    }
                }
                if resolutions.count > 1 {
                    row("RESOLUTION") {
                        ForEach(resolutions) { r in
                            option(selected: r == resolution) {
                                HStack(alignment: .firstTextBaseline, spacing: 2) {
                                    Text("\(r.megapixels)").font(.system(size: 17, weight: .semibold))
                                    Text("MP").font(.system(size: 10, weight: .semibold)).baselineOffset(6)
                                }
                            } action: { selectResolution(r) }
                        }
                    }
                }
                if formats.count <= 1 && resolutions.count <= 1 {
                    Text("This camera has one photo format.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: 520)
        .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .kerning(0.8)
                .foregroundStyle(.white)
                .frame(width: 112, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func option<Label: View>(selected: Bool, @ViewBuilder label: () -> Label,
                                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(.yellow).frame(width: 5, height: 5).opacity(selected ? 1 : 0)
                label()
            }
            .foregroundStyle(selected ? .yellow : .white)
            .frame(minWidth: 90, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
