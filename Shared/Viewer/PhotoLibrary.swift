import CoreLocation
import ImageIO
import Photos
import SwiftUI

/// The camera roll, for the in-app photo viewer. Photos are read from the fetch result on
/// demand, so opening the viewer stays instant even with tens of thousands of photos.
@MainActor
@Observable
final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    /// Number of photos, oldest first like the Photos app's scrubber.
    private(set) var count = 0
    /// Bumped whenever the library changes (a photo is added, deleted, hidden, favorited or edited).
    private(set) var version = 0

    @ObservationIgnored private var fetchResult: PHFetchResult<PHAsset>?
    @ObservationIgnored private let imageManager = PHCachingImageManager()
    @ObservationIgnored private var observing = false

    var canBrowse: Bool { status == .authorized || status == .limited }

    func load() async {
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard canBrowse else { return }
        if !observing {
            observing = true
            PHPhotoLibrary.shared().register(self)
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        apply(PHAsset.fetchAssets(with: options))
    }

    /// Call when the viewer goes away; Photos holds on to change observers until they're removed.
    func stopObserving() {
        guard observing else { return }
        observing = false
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    private func apply(_ result: PHFetchResult<PHAsset>) {
        fetchResult = result
        count = result.count
        version += 1
    }

    func asset(at index: Int) -> PHAsset? {
        guard let fetchResult, index >= 0, index < fetchResult.count else { return nil }
        return fetchResult.object(at: index)
    }

    /// Where a photo is now, after deletes and inserts. Matches by identifier, so an older
    /// copy of the asset works.
    func index(of asset: PHAsset) -> Int? {
        guard let fetchResult else { return nil }
        let i = fetchResult.index(of: asset)
        return i == NSNotFound ? nil : i
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            guard let fetchResult, let details = changeInstance.changeDetails(for: fetchResult) else { return }
            self.apply(details.fetchResultAfterChanges)
        }
    }

    // MARK: - Images

    func image(for asset: PHAsset, size: CGSize, contentMode: PHImageContentMode = .aspectFit) async -> PlatformImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        let manager = imageManager
        let box = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.id = manager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: options) { image, _ in
                    box.resumeOnce { continuation.resume(returning: image) }
                }
            }
        } onCancel: {
            // Swiping fast cancels pages that scrolled away, so stop their (maybe iCloud) loads too.
            if let id = box.id { manager.cancelImageRequest(id) }
        }
    }

    /// For the native pagers: a fast low-quality image first, then the sharp one, on the main thread.
    @discardableResult
    func requestImage(for asset: PHAsset, size: CGSize, contentMode: PHImageContentMode = .aspectFit,
                      handler: @escaping (PlatformImage?, _ isFinal: Bool) -> Void) -> PHImageRequestID {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.resizeMode = .fast
        return imageManager.requestImage(for: asset, targetSize: size, contentMode: contentMode, options: options) { image, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            handler(image, !degraded)
        }
    }

    func cancelRequest(_ id: PHImageRequestID) {
        imageManager.cancelImageRequest(id)
    }

    /// Loads the photos next to the one on screen ahead of time, so swiping never shows a blank page.
    func preheat(_ indexes: [Int], size: CGSize) {
        let assets = indexes.compactMap(asset(at:))
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(for: assets, targetSize: size, contentMode: .aspectFit, options: nil)
    }

    func imageData(for asset: PHAsset) async -> (data: Data, uti: String?)? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        return await withCheckedContinuation { continuation in
            imageManager.requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                continuation.resume(returning: data.map { ($0, uti) })
            }
        }
    }

    /// Writes the photo as it is in the library (edits included, full resolution, original
    /// format and metadata) to a temporary file, for sharing.
    nonisolated static func exportOriginal(of asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var name = resource.originalFilename
        if resource.type == .fullSizePhoto, let original = resources.first(where: { $0.type == .photo }) {
            // Edited photos are stored as "FullSizeRender"; share them under the photo's own name.
            let ext = (name as NSString).pathExtension
            name = ((original.originalFilename as NSString).deletingPathExtension as NSString).appendingPathExtension(ext) ?? name
        }
        let url = folder.appendingPathComponent(name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options)
        return url
    }

    // MARK: - Actions

    func toggleFavorite(_ asset: PHAsset) async {
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isFavorite = !asset.isFavorite
        }
    }

    func hide(_ asset: PHAsset) async {
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).isHidden = true
        }
    }

    /// The system asks the user to confirm; deleted photos go to Recently Deleted.
    func delete(_ asset: PHAsset) async {
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }

    // MARK: - Info

    func info(for asset: PHAsset) async -> PhotoInfo {
        var info = PhotoInfo(date: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight)
        info.filename = PHAssetResource.assetResources(for: asset).first?.originalFilename
        if let (data, uti) = await imageData(for: asset) {
            info.fileSize = data.count
            info.format = PhotoInfo.formatName(uti: uti)
            if let source = CGImageSourceCreateWithData(data as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                info.read(props)
            }
        }
        if let location = asset.location {
            info.place = await PhotoInfo.placeName(for: location)
        }
        return info
    }
}

/// What the viewer's info panel shows, read from the photo's metadata.
struct PhotoInfo {
    var date: Date?
    var width: Int
    var height: Int
    var filename: String?
    var fileSize: Int?
    var format: String?
    var place: String?
    var make: String?
    var model: String?
    var lens: String?
    var focalLength35: Double?
    var aperture: Double?
    var iso: Int?
    var exposureBias: Double?
    var exposureTime: Double?

    mutating func read(_ props: [CFString: Any]) {
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        make = tiff[kCGImagePropertyTIFFMake] as? String
        model = tiff[kCGImagePropertyTIFFModel] as? String
        lens = exif[kCGImagePropertyExifLensModel] as? String
        focalLength35 = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue
        aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        exposureBias = (exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue
        exposureTime = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
    }

    var deviceName: String? {
        guard let model else { return nil }
        // "NIKON CORPORATION" + "NIKON D800E" reads as "NIKON D800E", like Photos.
        guard let make, let brand = make.split(separator: " ").first,
              !model.lowercased().contains(brand.lowercased()) else { return model }
        return "\(make) \(model)"
    }

    /// "Main Camera — 24 mm ƒ1.78", like the Photos app.
    var lensDescription: String? {
        var name: String?
        if let lens = lens?.lowercased() {
            if lens.contains("front") { name = "Front Camera" }
            else if lens.contains("ultra") || lens.contains("1.54mm") || lens.contains("2.22mm") { name = "Ultra Wide Camera" }
            else if lens.contains("telephoto") || (focalLength35 ?? 0) > 50 { name = "Telephoto Camera" }
            else { name = "Main Camera" }
        }
        var specs: [String] = []
        if let focalLength35 { specs.append("\(Int(focalLength35.rounded())) mm") }
        if let aperture { specs.append("ƒ\(Self.trim(aperture))") }
        let joined = specs.joined(separator: " ")
        switch (name, joined.isEmpty) {
        case let (name?, false): return "\(name) — \(joined)"
        case let (name?, true): return name
        case (nil, false): return joined
        default: return nil
        }
    }

    var sizeDescription: String {
        let mp = max(1, Int((Double(width * height) / 1_000_000).rounded()))
        var parts = ["\(mp) MP", "\(width) × \(height)"]
        if let fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }

    var exposureItems: [String] {
        var items: [String] = []
        if let iso { items.append("ISO \(iso)") }
        if let focalLength35 { items.append("\(Int(focalLength35.rounded())) mm") }
        if let exposureBias { items.append("\(Self.trim(exposureBias)) ev") }
        if let aperture { items.append("ƒ\(Self.trim(aperture))") }
        if let exposureTime {
            items.append(exposureTime < 1 ? "1/\(Int((1 / exposureTime).rounded())) s" : "\(Self.trim(exposureTime)) s")
        }
        return items
    }

    /// "Wednesday • Aug 8, 2012 • 2:52 PM"
    var dateDescription: String? {
        guard let date else { return nil }
        return [date.formatted(.dateTime.weekday(.wide)),
                date.formatted(.dateTime.month(.abbreviated).day().year()),
                date.formatted(date: .omitted, time: .shortened)].joined(separator: " • ")
    }

    static func trim(_ value: Double) -> String {
        let s = String(format: "%.2f", value)
        return s.replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    static func formatName(uti: String?) -> String? {
        guard let uti else { return nil }
        if uti.contains("heic") || uti.contains("heif") { return "HEIF" }
        if uti.contains("jpeg") { return "JPEG" }
        if uti.contains("raw") || uti.contains("dng") { return "RAW" }
        if uti.contains("png") { return "PNG" }
        return uti.components(separatedBy: ".").last?.uppercased()
    }

    static func placeName(for location: CLLocation) async -> String? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let place = placemarks?.first else { return nil }
        return place.locality ?? place.subLocality ?? place.name
    }
}

/// Holds an image request's ID for cancellation, and makes sure the continuation resumes once.
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    var id: PHImageRequestID?

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}

/// Shares the original file, like the Photos app, rather than a re-rendered copy.
struct PhotoShareItem: Transferable {
    let asset: PHAsset

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { item in
            SentTransferredFile(try await PhotoLibrary.exportOriginal(of: item.asset))
        }
    }
}
