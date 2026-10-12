import Foundation
import Photos

/// Saves captures to the Photos library, falling back to the Pictures folder on the Mac.
enum MediaSaver {
    /// Saves the photo exactly as captured (HEIF, JPEG or ProRAW DNG), without re-encoding.
    static func savePhoto(_ data: Data, isRAW: Bool = false) async {
        if await canAddToLibrary() {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    if isRAW { options.uniformTypeIdentifier = "com.adobe.raw-image" }
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: options)
                }
                return
            } catch {}
        }
        #if os(macOS)
        try? data.write(to: fallbackURL(extension: isRAW ? "dng" : (FileType.isJPEG(data) ? "jpg" : "heic")))
        #endif
    }

    private enum FileType {
        static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8]) }
    }

    private static func canAddToLibrary() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }

    #if os(macOS)
    private static func fallbackURL(extension ext: String) -> URL {
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SmartShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return folder.appendingPathComponent("SmartShot \(formatter.string(from: Date())).\(ext)")
    }
    #endif
}
