import Photos
import SwiftUI

/// A Photos-app style viewer for the camera roll, opened from the camera's thumbnail.
struct PhotoViewer: View {
    let close: () -> Void

    @State private var library = PhotoLibrary()
    /// Index of the photo on screen. Indexes (not identifiers) keep huge libraries fast.
    @State private var selection: Int?
    @State private var current: PHAsset?
    @State private var lastIndex = 0
    @State private var chromeVisible = true
    @State private var showingInfo = false
    @State private var editing: PHAsset?
    @State private var places: [String: String] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            // Wide windows (Mac, iPad, landscape) show Info as a side panel, like Photos on the Mac.
            let infoOnSide = Self.isMac || geo.size.width > 700
            HStack(spacing: 0) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if library.canBrowse {
                        pager
                        chrome(infoOnSide: infoOnSide)
                    } else if library.status != .notDetermined {
                        accessNeeded
                    }
                }
                if showingInfo, infoOnSide, let current {
                    PhotoInfoCard(asset: current, library: library, close: closeInfo)
                        .frame(width: 340)
                        .background(Color(white: 0.07).ignoresSafeArea())
                        .transition(.move(edge: .trailing))
                }
            }
            .overlay(alignment: .bottom) {
                if showingInfo, !infoOnSide, let current {
                    PhotoInfoCard(asset: current, library: library, close: closeInfo)
                        .frame(maxHeight: geo.size.height * 0.55)
                        .background(Color(white: 0.07), in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
                        .gesture(DragGesture().onEnded { if $0.translation.height > 60 { closeInfo() } })
                        .transition(.move(edge: .bottom))
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .preferredColorScheme(.dark)
        #if os(iOS)
        .statusBarHidden(!chromeVisible)
        .persistentSystemOverlays(chromeVisible ? .automatic : .hidden)
        #endif
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
        .animation(.spring(duration: 0.35), value: showingInfo)
        .task {
            await library.load()
            selection = library.count > 0 ? library.count - 1 : nil
            lastIndex = max(0, library.count - 1)
            current = selection.flatMap(library.asset(at:))
        }
        .onDisappear { library.stopObserving() }
        .onChange(of: library.version) {
            // After a delete or hide, stay on the same photo if it's still there, or land on its
            // neighbour, like Photos does. Edits and favorites refresh the current photo.
            if let current, let i = library.index(of: current) {
                selection = i
            } else {
                selection = library.count > 0 ? min(lastIndex, library.count - 1) : nil
            }
            current = selection.flatMap(library.asset(at:))
            if current == nil { showingInfo = false }
        }
        .onChange(of: selection) { _, index in
            if let index { lastIndex = index }
            current = index.flatMap(library.asset(at:))
        }
        #if os(iOS)
        .fullScreenCover(item: $editing) { asset in
            PhotoEditor(asset: asset) { editing = nil }
        }
        #else
        .sheet(item: $editing) { asset in
            PhotoEditor(asset: asset) { editing = nil }
                .frame(minWidth: 820, idealWidth: 1000, minHeight: 720, idealHeight: 820)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) {
            if showingInfo { closeInfo() } else { close() }
            return .handled
        }
        .onKeyPress("i") { toggleInfo(); return .handled }
        #endif
    }

    private static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private func toggleInfo() {
        guard current != nil else { return }
        showingInfo.toggle()
    }

    private func closeInfo() {
        showingInfo = false
    }

    // MARK: - Pager

    private var pager: some View {
        PhotoPager(library: library, count: library.count, version: library.version, selection: $selection) {
            // With Info open, tapping the photo closes it; otherwise it hides the controls.
            if showingInfo { closeInfo() } else { chromeVisible.toggle() }
        }
        .ignoresSafeArea()
    }

    private func step(_ delta: Int) {
        guard let selection, library.count > 0 else { return }
        let next = min(max(selection + delta, 0), library.count - 1)
        withAnimation { self.selection = next }
    }

    // MARK: - Chrome

    @ViewBuilder private func chrome(infoOnSide: Bool) -> some View {
        if chromeVisible {
            VStack(spacing: 0) {
                topBar
                Spacer()
                if !(showingInfo && !infoOnSide) {
                    bottomBar
                }
            }
            .transition(.opacity)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            GlassIconButton(symbol: "chevron.left", size: 44, action: close)
                .accessibilityLabel("Back to camera")

            Spacer(minLength: 0)

            if let current {
                VStack(spacing: 1) {
                    Text(title(for: current))
                        .font(.system(size: 16, weight: .semibold))
                    Text(subtitle(for: current))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .glass(in: Capsule())
                .task(id: current.localIdentifier) { await loadPlace(for: current) }
            }

            Spacer(minLength: 0)

            moreMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var moreMenu: some View {
        Menu {
            if let current {
                Button { Task { await copy(current) } } label: { Label("Copy", systemImage: "doc.on.doc") }
                Button { Task { await library.toggleFavorite(current) } } label: {
                    Label(current.isFavorite ? "Unfavorite" : "Favorite", systemImage: current.isFavorite ? "heart.slash" : "heart")
                }
                Button(action: toggleInfo) {
                    Label(showingInfo ? "Hide Info" : "Show Info", systemImage: "info.circle")
                }
                if current.canPerform(.content) {
                    Button { editing = current } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                }
                Button { Task { await library.hide(current) } } label: { Label("Hide", systemImage: "eye.slash") }
            }
            #if os(iOS)
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: { Label("Open in Photos", systemImage: "photo.on.rectangle") }
            #endif
            if let current {
                Divider()
                Button(role: .destructive) { Task { await library.delete(current) } } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .glass(in: Circle())
        .accessibilityLabel("More")
    }

    private var bottomBar: some View {
        VStack(spacing: 14) {
            Scrubber(library: library, selection: $selection)
                .frame(height: 46)

            HStack {
                shareButton

                Spacer()

                HStack(spacing: 30) {
                    Button { if let current { Task { await library.toggleFavorite(current) } } } label: {
                        Image(systemName: current?.isFavorite == true ? "heart.fill" : "heart")
                            .foregroundStyle(current?.isFavorite == true ? .red : .white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: current?.isFavorite)
                    .accessibilityLabel(current?.isFavorite == true ? "Unfavorite" : "Favorite")
                    Button(action: toggleInfo) {
                        Image(systemName: showingInfo ? "info.circle.fill" : "info.circle")
                    }
                    .accessibilityLabel("Info")
                    Button { editing = current } label: { Image(systemName: "slider.horizontal.3") }
                        .disabled(current?.canPerform(.content) != true)
                        .accessibilityLabel("Edit")
                }
                .buttonStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.white)
                .padding(.horizontal, 26)
                .frame(height: 50)
                .glass(in: Capsule())

                Spacer()

                GlassIconButton(symbol: "trash", size: 50) {
                    if let current { Task { await library.delete(current) } }
                }
                .accessibilityLabel("Delete")
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
        .disabled(current == nil)
    }

    @ViewBuilder private var shareButton: some View {
        if let current {
            ShareLink(item: PhotoShareItem(asset: current), preview: SharePreview(title(for: current))) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glass(in: Circle())
            .accessibilityLabel("Share")
        } else {
            GlassIconButton(symbol: "square.and.arrow.up", size: 50) {}
                .disabled(true)
        }
    }

    // MARK: - Helpers

    private var accessNeeded: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Allow Access to Photos")
                .font(.title3.weight(.semibold))
            Text("To see your photos here, allow SmartShot full access to Photos in Settings.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close", action: close)
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .foregroundStyle(.black)
        }
        .padding(32)
    }

    private func title(for asset: PHAsset) -> String {
        places[asset.localIdentifier] ?? dayString(asset.creationDate)
    }

    private func subtitle(for asset: PHAsset) -> String {
        let time = asset.creationDate?.formatted(date: .omitted, time: .shortened) ?? ""
        return places[asset.localIdentifier] != nil ? "\(dayString(asset.creationDate))  \(time)" : time
    }

    private func dayString(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private func loadPlace(for asset: PHAsset) async {
        guard places[asset.localIdentifier] == nil, let location = asset.location else { return }
        // Wait a moment so swiping through photos doesn't fire a lookup for each one.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, let name = await PhotoInfo.placeName(for: location) else { return }
        places[asset.localIdentifier] = name
    }

    /// Copies the full-quality photo, as Photos does.
    private func copy(_ asset: PHAsset) async {
        guard let (data, uti) = await library.imageData(for: asset) else { return }
        let type = uti ?? "public.jpeg"
        #if os(iOS)
        UIPasteboard.general.setData(data, forPasteboardType: type)
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType(type))
        #endif
    }
}

extension PHAsset: @retroactive Identifiable {
    public var id: String { localIdentifier }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

// MARK: - Scrubber

/// The strip of thumbnails at the bottom. Drag it to scrub through photos, like Photos.
private struct Scrubber: View {
    let library: PhotoLibrary
    @Binding var selection: Int?
    /// The thumbnail under the centre line while you drag.
    @State private var centered: Int?

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 2) {
                        ForEach(0..<library.count, id: \.self) { index in
                            let selected = index == selection
                            Thumbnail(index: index, library: library, version: library.version)
                                .frame(width: 30, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                // Grow without changing the layout, so scrubbing never jumps.
                                .scaleEffect(selected ? 1.25 : 1)
                                .zIndex(selected ? 1 : 0)
                                .padding(.horizontal, selected ? 4 : 0)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { selection = index }
                        }
                    }
                    // Lets the first and last photos scroll to the middle.
                    .padding(.horizontal, max(0, geo.size.width / 2 - 15))
                    .scrollTargetLayout()
                }
                // The viewer opens on the newest photo, so start at the end: centred on the first frame.
                .defaultScrollAnchor(.trailing)
                .scrollTargetBehavior(.viewAligned)
                .scrollPosition(id: $centered, anchor: .center)
                .scrollIndicators(.hidden)
                .onChange(of: centered) { _, index in
                    // Dragging the strip picks the photo under the centre.
                    if let index, index != selection { selection = index }
                }
                .onChange(of: selection) { _, index in
                    guard let index, index != centered else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                }
                .task(id: library.count) {
                    // After a delete the current photo may not be the last; recentre once the
                    // opening animation has settled.
                    try? await Task.sleep(for: .milliseconds(450))
                    if let selection, selection != library.count - 1 { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
        .animation(.spring(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

private struct Thumbnail: View {
    let index: Int
    let library: PhotoLibrary
    let version: Int
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(platformImage: image).resizable().scaledToFill()
            }
        }
        .task(id: "\(index)-\(version)") {
            guard let asset = library.asset(at: index) else { return }
            image = await library.image(for: asset, size: CGSize(width: 120, height: 120), contentMode: .aspectFill)
        }
    }
}

// MARK: - Info

/// The info card from the Photos app: date, file, camera, lens, size and exposure.
private struct PhotoInfoCard: View {
    let asset: PHAsset
    let library: PhotoLibrary
    let close: () -> Void
    @State private var info: PhotoInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Info").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Info")
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                if let info {
                    card(info).padding(16)
                } else {
                    ProgressView().padding(40)
                }
            }
        }
        .foregroundStyle(.white)
        // Follows edits and favorites, and the photo you swipe to.
        .task(id: "\(asset.localIdentifier)-\(asset.modificationDate?.timeIntervalSince1970 ?? 0)") {
            info = nil
            info = await library.info(for: asset)
        }
    }

    private func card(_ info: PhotoInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if let date = info.dateDescription {
                    Text(date).font(.system(size: 17, weight: .medium))
                }
                if let filename = info.filename {
                    Label(filename, systemImage: "photo")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
                if let place = info.place {
                    Label(place, systemImage: "mappin.and.ellipse")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            HStack {
                Text(info.deviceName ?? "Unknown Camera")
                    .font(.system(size: 17, weight: .medium))
                Spacer()
                if let format = info.format {
                    Text(format)
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                if let lens = info.lensDescription { Text(lens) }
                Text(info.sizeDescription)
            }
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            if !info.exposureItems.isEmpty {
                Divider()
                HStack(spacing: 0) {
                    ForEach(Array(info.exposureItems.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Divider().frame(height: 20) }
                        Text(item)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 14)
            }
        }
        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
