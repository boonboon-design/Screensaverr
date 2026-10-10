import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Downloads, downsamples and caches artwork (memory + disk).
@MainActor
final class ImageStore {
    static let shared = ImageStore()

    enum Variant: String {
        case poster
        case backdrop

        var maxPixelSize: Int {
            switch self {
            case .poster: return 600
            case .backdrop: return 1920
            }
        }
    }

    /// Supplies API keys for artwork served by Sonarr/Radarr themselves.
    var apiKeyProvider: (ServiceKind) -> String? = { _ in nil }

    private let memory = NSCache<NSString, NSImage>()
    private var waiters: [String: [(NSImage?) -> Void]] = [:]
    private var failures: [String: Date] = [:]
    private let directory: URL?
    private let http: HTTPClient

    init(http: HTTPClient = .shared) {
        self.http = http
        memory.countLimit = 300
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Screensaverr/Artwork", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            Self.pruneDiskCache(directory)
        }
    }

    func cachedImage(_ ref: ImageRef?, variant: Variant) -> NSImage? {
        guard let key = key(ref, variant) else { return nil }
        return memory.object(forKey: key as NSString)
    }

    /// Calls `completion` on the main thread with the image (or nil). Never calls it synchronously.
    func load(_ ref: ImageRef?, variant: Variant, completion: @escaping (NSImage?) -> Void) {
        guard let ref, let key = key(ref, variant) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let image = memory.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(image) }
            return
        }
        if let failedAt = failures[key], Date().timeIntervalSince(failedAt) < 10 * 60 {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if waiters[key] != nil {
            waiters[key]?.append(completion)
            return
        }
        waiters[key] = [completion]

        let fileURL = directory?.appendingPathComponent(Self.fileName(for: key))
        let apiKey = ref.service.flatMap { apiKeyProvider($0) }
        let http = self.http
        Task.detached(priority: .utility) { [self] in
            let image = await Self.fetch(ref: ref, variant: variant, fileURL: fileURL, apiKey: apiKey, http: http)
            await self.deliver(key: key, image: image)
        }
    }

    private func deliver(key: String, image: NSImage?) {
        if let image {
            memory.setObject(image, forKey: key as NSString)
            failures[key] = nil
        } else {
            failures[key] = Date()
        }
        let callbacks = waiters.removeValue(forKey: key) ?? []
        for callback in callbacks { callback(image) }
    }

    private func key(_ ref: ImageRef?, _ variant: Variant) -> String? {
        guard let base = ref?.cacheKey else { return nil }
        return variant.rawValue + "|" + base
    }

    // MARK: Off-main work

    private nonisolated static func fetch(
        ref: ImageRef,
        variant: Variant,
        fileURL: URL?,
        apiKey: String?,
        http: HTTPClient
    ) async -> NSImage? {
        if let fileURL, let data = try? Data(contentsOf: fileURL), let image = decode(data, maxPixelSize: nil) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }

        var attempts: [HTTPRequest] = []
        if let remote = ref.remoteURL {
            attempts.append(HTTPRequest(url: remote, timeout: 20))
        }
        if let local = ref.localURL {
            var request = HTTPRequest(url: local, timeout: 20)
            if let apiKey, !apiKey.isEmpty { request.headers["X-Api-Key"] = apiKey }
            attempts.append(request)
        }

        for request in attempts {
            guard let response = try? await http.perform(request), response.isSuccess,
                  let image = decode(response.body, maxPixelSize: variant.maxPixelSize)
            else { continue }
            if let fileURL, let jpeg = encodeJPEG(image) {
                try? jpeg.write(to: fileURL, options: .atomic)
            }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
        return nil
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { return nil }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private nonisolated static func fileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Drops artwork nobody has looked at for 30 days.
    private nonisolated static func pruneDiskCache(_ directory: URL) {
        DispatchQueue.global(qos: .background).async {
            let fileManager = FileManager.default
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let cutoff = Date().addingTimeInterval(-30 * 86_400)
            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < cutoff { try? fileManager.removeItem(at: file) }
            }
        }
    }
}
