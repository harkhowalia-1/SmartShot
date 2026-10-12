import AVFoundation
import SwiftUI

/// Hosts the model's preview layer.
#if os(iOS)
struct PreviewLayerView: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        view.previewLayer = layer
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {}

    final class HostView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let previewLayer { layer.addSublayer(previewLayer) }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
#else
struct PreviewLayerView: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.previewLayer = layer
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {}

    final class HostView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer? {
            didSet {
                oldValue?.removeFromSuperlayer()
                if let previewLayer { layer?.addSublayer(previewLayer) }
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer?.frame = bounds
            CATransaction.commit()
        }
    }
}
#endif

/// Live feedback over each face, like the native camera's face boxes,
/// with a hint for whoever is holding things up.
struct FaceOverlay: View {
    let faces: [FaceStatus]
    let armed: Bool

    var body: some View {
        GeometryReader { geo in
            ForEach(faces) { face in
                let rect = CGRect(x: face.box.minX * geo.size.width,
                                  y: face.box.minY * geo.size.height,
                                  width: face.box.width * geo.size.width,
                                  height: face.box.height * geo.size.height)
                    .insetBy(dx: -12, dy: -12)
                let side = max(rect.width, rect.height)
                let color: Color = face.isReady ? .yellow : .white.opacity(0.85)

                ZStack(alignment: .bottom) {
                    FaceBracket()
                        .stroke(color, style: StrokeStyle(lineWidth: face.isReady ? 1.5 : 1, lineCap: .round))
                        .frame(width: side, height: side)

                    if armed, let hint = hint(for: face) {
                        Image(systemName: hint)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(width: 22, height: 22)
                            .background(.yellow, in: Circle())
                            .offset(y: 11)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: side, height: side)
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeOut(duration: 0.12), value: face.box)
                .animation(.easeOut(duration: 0.2), value: face.isReady)
            }
        }
        .allowsHitTesting(false)
    }

    private func hint(for face: FaceStatus) -> String? {
        if !face.facingCamera { return "eyes" }
        if !face.still { return "hand.raised.fill" }
        if !face.eyesOpen { return "eye.slash.fill" }
        return nil
    }
}

/// Four corner brackets, like the native camera's focus/face square.
struct FaceBracket: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = rect.width * 0.18
        var path = Path()
        for (corner, dx, dy) in [(CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
                                 (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
                                 (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
                                 (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
        }
        return path
    }
}
