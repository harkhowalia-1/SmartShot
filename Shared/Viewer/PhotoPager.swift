import Photos
import SwiftUI

/// The swipeable, zoomable photo pages, built on the system's own scroll views so paging,
/// zooming, bouncing and momentum feel exactly like the Photos app.
struct PhotoPager {
    let library: PhotoLibrary
    let count: Int
    let version: Int
    @Binding var selection: Int?
    var onTap: () -> Void = {}
}

#if os(iOS)
import UIKit

extension PhotoPager: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> PagerViewController {
        PagerViewController(library: library)
    }

    func updateUIViewController(_ controller: PagerViewController, context: Context) {
        controller.onTap = onTap
        controller.onSelect = { index in
            if selection != index { selection = index }
        }
        controller.update(count: count, version: version, selection: selection)
    }
}

/// A horizontally paging collection of zooming photo pages, with the gap between photos
/// that Photos shows while you swipe.
final class PagerViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let library: PhotoLibrary
    private let gap: CGFloat = 20
    private var count = 0
    private var version = -1
    private var currentIndex = 0
    private var lastSize: CGSize = .zero
    var onTap: () -> Void = {}
    var onSelect: (Int) -> Void = { _ in }

    private lazy var layout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.isPagingEnabled = true
        view.showsHorizontalScrollIndicator = false
        view.backgroundColor = .clear
        view.contentInsetAdjustmentBehavior = .never
        view.decelerationRate = .fast
        view.dataSource = self
        view.delegate = self
        view.register(PhotoPageCell.self, forCellWithReuseIdentifier: "page")
        return view
    }()

    init(library: PhotoLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.clipsToBounds = true
        view.addSubview(collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The collection is wider than the screen by the gap, so each page carries half a gap
        // on either side and paging still lands exactly on a photo.
        collectionView.frame = view.bounds.insetBy(dx: -gap / 2, dy: 0)
        guard collectionView.bounds.size != lastSize, collectionView.bounds.width > 0 else { return }
        lastSize = collectionView.bounds.size
        layout.itemSize = collectionView.bounds.size
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        scroll(to: currentIndex, animated: false)
    }

    func update(count: Int, version: Int, selection: Int?) {
        if version != self.version || count != self.count {
            self.version = version
            self.count = count
            currentIndex = min(max(selection ?? count - 1, 0), max(count - 1, 0))
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            scroll(to: currentIndex, animated: false)
            preheat()
            return
        }
        guard let selection, selection != currentIndex,
              !collectionView.isDragging, !collectionView.isDecelerating else { return }
        // Scrubbing and tapping thumbnails cut straight to the photo, as in Photos.
        currentIndex = selection
        scroll(to: selection, animated: false)
        preheat()
    }

    private func scroll(to index: Int, animated: Bool) {
        guard index >= 0, index < count, collectionView.bounds.width > 0 else { return }
        collectionView.setContentOffset(CGPoint(x: CGFloat(index) * collectionView.bounds.width, y: 0), animated: animated)
    }

    private func preheat() {
        let size = targetSize
        library.preheat([currentIndex - 1, currentIndex + 1, currentIndex + 2, currentIndex - 2], size: size)
    }

    private var targetSize: CGSize {
        let scale = view.window?.screen.scale ?? 3
        let side = max(view.bounds.width, view.bounds.height) * scale
        return CGSize(width: side, height: side)
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath) as! PhotoPageCell
        cell.gap = gap
        cell.onTap = { [weak self] in self?.onTap() }
        cell.show(index: indexPath.item, library: library, targetSize: targetSize)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        // A photo that scrolls away comes back unzoomed, as in Photos.
        (cell as? PhotoPageCell)?.resetZoom()
    }

    // MARK: Paging

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === collectionView, scrollView.bounds.width > 0, scrollView.isTracking || scrollView.isDecelerating else { return }
        let page = Int((scrollView.contentOffset.x / scrollView.bounds.width).rounded())
        guard page != currentIndex, page >= 0, page < count else { return }
        currentIndex = page
        onSelect(page)
        preheat()
    }
}

/// One page: a zooming scroll view inset by half the gap on each side.
private final class PhotoPageCell: UICollectionViewCell {
    let zoomView = ZoomingImageView()
    var gap: CGFloat = 20
    var onTap: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(zoomView)
        zoomView.onTap = { [weak self] in self?.onTap() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        zoomView.frame = contentView.bounds.insetBy(dx: gap / 2, dy: 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        zoomView.prepareForReuse()
    }

    func show(index: Int, library: PhotoLibrary, targetSize: CGSize) {
        zoomView.load(index: index, library: library, targetSize: targetSize)
    }

    func resetZoom() {
        zoomView.setZoomScale(zoomView.minimumZoomScale, animated: false)
    }
}

/// A photo in a UIScrollView: pinch zooms around your fingers, double-tap zooms where you tap,
/// edges bounce, and panning past the edge of a zoomed photo hands over to paging.
final class ZoomingImageView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var imageAspect: CGFloat = 0
    private var lastBounds: CGSize = .zero
    private weak var library: PhotoLibrary?
    private var index = -1
    private var requestID: PHImageRequestID?
    private var detailRequested = false
    var onTap: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        bouncesZoom = true
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func prepareForReuse() {
        if let requestID { library?.cancelRequest(requestID) }
        requestID = nil
        imageView.image = nil
        imageAspect = 0
        detailRequested = false
        zoomScale = 1
    }

    func load(index: Int, library: PhotoLibrary, targetSize: CGSize) {
        self.index = index
        self.library = library
        guard let asset = library.asset(at: index) else { return }
        imageAspect = asset.pixelHeight > 0 ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight) : 0
        layoutForImage()
        requestID = library.requestImage(for: asset, size: targetSize) { [weak self] image, _ in
            guard let self, self.index == index, let image else { return }
            self.imageView.image = image
        }
    }

    /// Zoomed in past the screen's resolution: fetch a sharper copy.
    private func loadDetailIfNeeded() {
        guard !detailRequested, zoomScale > 1.4, let library, let asset = library.asset(at: index) else { return }
        detailRequested = true
        let index = self.index
        library.requestImage(for: asset, size: CGSize(width: 4096, height: 4096)) { [weak self] image, isFinal in
            guard let self, self.index == index, isFinal, let image else { return }
            self.imageView.image = image
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastBounds {
            lastBounds = bounds.size
            layoutForImage()
        }
        centerImage()
    }

    /// Sizes the image to fit the page at zoom 1.
    private func layoutForImage() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        zoomScale = 1
        let aspect = imageAspect > 0 ? imageAspect : bounds.width / bounds.height
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height { size = CGSize(width: bounds.height * aspect, height: bounds.height) }
        imageView.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        minimumZoomScale = 1
        // Enough to reach the photo's own pixels, and never less than Photos' generous zoom.
        maximumZoomScale = max(4, CGFloat(library?.asset(at: index)?.pixelWidth ?? 0) / max(size.width, 1) / 2)
        centerImage()
    }

    private func centerImage() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        loadDetailIfNeeded()
    }

    @objc private func handleSingleTap() { onTap() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: imageView)
            let scale = min(maximumZoomScale, 2.5)
            let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}

#else
import AppKit

extension PhotoPager: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> MacPagerController {
        MacPagerController(library: library)
    }

    func updateNSViewController(_ controller: MacPagerController, context: Context) {
        controller.onTap = onTap
        controller.onSelect = { index in
            if selection != index { selection = index }
        }
        controller.update(count: count, version: version, selection: selection)
    }
}

/// Shows one photo at a time and slides to the next with a push animation, like Preview.
/// Two-finger swipes on the trackpad page through photos.
final class MacPagerController: NSViewController {
    private let library: PhotoLibrary
    private var count = 0
    private var version = -1
    private var index = -1
    private var page: MacPhotoPage?
    var onTap: () -> Void = {}
    var onSelect: (Int) -> Void = { _ in }

    init(library: PhotoLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let container = SwipeContainerView()
        container.wantsLayer = true
        container.onSwipe = { [weak self] direction in self?.step(direction) }
        view = container
    }

    func update(count: Int, version: Int, selection: Int?) {
        guard count > 0 else {
            self.count = 0
            page?.view.removeFromSuperview()
            page = nil
            index = -1
            return
        }
        let target = min(max(selection ?? count - 1, 0), count - 1)
        if version != self.version || count != self.count || page == nil {
            // The library changed (or first load): show the right photo without animating.
            self.version = version
            self.count = count
            show(target, direction: 0)
        } else if target != index {
            show(target, direction: target > index ? 1 : -1)
        }
    }

    private func step(_ direction: Int) {
        let next = index + direction
        guard next >= 0, next < count else {
            // At either end, give a little bounce instead of moving.
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            return
        }
        show(next, direction: direction)
        onSelect(next)
    }

    private func show(_ newIndex: Int, direction: Int) {
        let newPage = MacPhotoPage()
        newPage.onTap = { [weak self] in self?.onTap() }
        _ = newPage.view
        newPage.view.frame = view.bounds
        newPage.view.autoresizingMask = [.width, .height]

        if direction != 0, let layer = view.layer {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = direction > 0 ? .fromRight : .fromLeft
            transition.duration = 0.28
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            layer.add(transition, forKey: "page")
        }
        page?.view.removeFromSuperview()
        view.addSubview(newPage.view)
        page = newPage
        index = newIndex
        newPage.show(index: newIndex, library: library)
        library.preheat([newIndex - 1, newIndex + 1], size: CGSize(width: 2400, height: 2400))
    }
}

/// Turns a two-finger horizontal trackpad swipe into one page step.
private final class SwipeContainerView: NSView {
    var onSwipe: (Int) -> Void = { _ in }
    private var travel: CGFloat = 0
    private var fired = false

    override func scrollWheel(with event: NSEvent) {
        // Only real trackpad gestures; momentum after lifting the fingers is ignored.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) {
            travel = 0
            fired = false
        }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || travel != 0 else { return }
        // Which way the fingers moved, whatever the natural-scrolling setting.
        let fingerDelta = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
        travel += fingerDelta
        if !fired, abs(travel) > 50 {
            fired = true
            // Fingers moving left bring in the next photo, like Photos and Preview.
            onSwipe(travel < 0 ? 1 : -1)
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            travel = 0
            fired = false
        }
    }
}

/// One Mac page: an NSScrollView with native pinch and smart zoom, the photo centred inside.
final class MacPhotoPage: NSViewController {
    private let scrollView = PageScrollView()
    private let imageView = NSImageView()
    private var index = -1
    private var imageAspect: CGFloat = 0
    private var requestID: PHImageRequestID?
    private weak var library: PhotoLibrary?
    var onTap: () -> Void = {}

    override func loadView() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 8
        scrollView.contentView = CenteringClipView()
        scrollView.contentView.drawsBackground = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scrollView.documentView = imageView
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        click.delaysPrimaryMouseButtonEvents = false
        scrollView.addGestureRecognizer(doubleClick)
        scrollView.addGestureRecognizer(click)
        view = scrollView
    }

    func show(index: Int, library: PhotoLibrary) {
        if let requestID { library.cancelRequest(requestID) }
        self.index = index
        self.library = library
        scrollView.magnification = 1
        imageView.image = nil
        guard let asset = library.asset(at: index) else { return }
        imageAspect = asset.pixelHeight > 0 ? CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight) : 1
        layoutImage()
        requestID = library.requestImage(for: asset, size: CGSize(width: 2400, height: 2400)) { [weak self] image, _ in
            guard let self, self.index == index, let image else { return }
            self.imageView.image = image
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if scrollView.magnification <= 1.001 { layoutImage() }
    }

    private func layoutImage() {
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0, imageAspect > 0 else { return }
        var size = CGSize(width: bounds.width, height: bounds.width / imageAspect)
        if size.height > bounds.height { size = CGSize(width: bounds.height * imageAspect, height: bounds.height) }
        imageView.frame = CGRect(origin: .zero, size: size)
    }

    @objc private func handleClick() { onTap() }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: imageView)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            if scrollView.magnification > 1.01 {
                scrollView.animator().magnification = 1
            } else {
                scrollView.animator().setMagnification(2.5, centeredAt: point)
            }
        }
    }
}

/// Lets swipes through to the pager unless the photo is zoomed in (then they pan it).
private final class PageScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if magnification <= 1.001 {
            superview?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// Keeps a smaller-than-window photo centred, as Preview does.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
#endif
