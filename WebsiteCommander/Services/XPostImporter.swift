import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// Imports a public X post through the documented oEmbed endpoint only. It
/// never fetches the public x.com page and never follows links found in post
/// text.
final class XPostImporter {
    private static let oEmbedEndpoint = URL(string: "https://publish.x.com/oembed")!
    private static let maxImages = 4
    private static let maxImageBytes = 10 * 1024 * 1024
    private static let maxTotalImageBytes = 25 * 1024 * 1024

    private let assetStore: BlogImportAssetStore
    private let session: URLSession

    init(assetStore: BlogImportAssetStore = BlogImportAssetStore(), session: URLSession? = nil) {
        self.assetStore = assetStore
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration,
                                      delegate: XEmbedRedirectDelegate(), delegateQueue: nil)
        }
    }

    func importPost(from rawURL: String) async throws -> XPostImportDraft {
        guard !Task.isCancelled else { throw XPostImportError.cancelled }
        guard let inputURL = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw XPostImportError.invalidURL
        }
        guard let post = Self.parsePostURL(inputURL) else {
            throw XPostImportError.unsupportedURL
        }

        let sessionID = await assetStore.createSession()
        do {
            let response = try await fetchOEmbed(for: post.canonicalURL)
            let parsed = try XPostHTMLParser.parse(response.html)
            guard !parsed.text.isEmpty else { throw XPostImportError.emptyPost }

            var mediaURLs = parsed.mediaURLs
            if let thumbnail = response.thumbnailURL { mediaURLs.append(thumbnail) }
            mediaURLs = Array(Set(mediaURLs.filter(Self.isDirectOfficialImageURL))).prefix(Self.maxImages).map { $0 }

            let downloaded = await downloadImages(mediaURLs, sessionID: sessionID)
            var descriptors: [ImportedMediaAssetDescriptor] = []
            var seenHashes = Set<String>()
            var imageFailed = false
            for item in downloaded {
                switch item {
                case .success(let image):
                    if seenHashes.insert(image.sha256).inserted {
                        do {
                            let descriptor = try await assetStore.store(
                                data: image.data,
                                sessionID: sessionID,
                                mimeType: image.mimeType,
                                pixelWidth: image.width,
                                pixelHeight: image.height,
                                suggestedExtension: image.extension
                            )
                            descriptors.append(descriptor)
                        } catch {
                            imageFailed = true
                        }
                    }
                case .failure:
                    imageFailed = true
                }
            }

            var warnings: [XPostImportWarning] = []
            let mediaMentioned = parsed.hasMedia || response.thumbnailURL != nil
            if mediaMentioned && (parsed.hasVideo || descriptors.isEmpty) {
                warnings.append(.mediaUnavailable)
            }
            if imageFailed { warnings.append(.imageUnavailable) }
            if response.publishedAt == nil { warnings.append(.publicationDateUnavailable) }
            warnings = Array(Set(warnings)).sorted { $0.rawValue < $1.rawValue }

            return XPostImportDraft(
                id: sessionID,
                postID: post.postID,
                canonicalURL: post.canonicalURL,
                authorDisplayName: response.authorName,
                authorHandle: Self.authorHandle(from: response.authorURL) ?? post.handle,
                authorProfileURL: response.authorURL,
                sourceText: parsed.text,
                sourcePublishedAt: response.publishedAt,
                fetchedAt: Date(),
                media: descriptors,
                hasVideo: parsed.hasVideo,
                warnings: warnings
            )
        } catch let error as XPostImportError {
            await assetStore.cleanup(sessionID: sessionID)
            throw error
        } catch is CancellationError {
            await assetStore.cleanup(sessionID: sessionID)
            throw XPostImportError.cancelled
        } catch {
            await assetStore.cleanup(sessionID: sessionID)
            throw Self.mapNetworkError(error)
        }
    }

    // MARK: oEmbed

    private struct PostURL {
        let canonicalURL: URL
        let postID: String
        let handle: String
    }

    private static func parsePostURL(_ url: URL) -> PostURL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host) else {
            return nil
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 3,
              parts[1].lowercased() == "status",
              !parts[0].isEmpty,
              !parts[2].isEmpty,
              parts[2].allSatisfy({ $0.isNumber }) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.host = "x.com"
        components.port = nil
        components.path = "/\(parts[0])/status/\(parts[2])"
        components.query = nil
        components.fragment = nil
        guard let canonical = components.url else { return nil }
        return PostURL(canonicalURL: canonical, postID: parts[2], handle: parts[0])
    }

    private struct OEmbedResponse: Decodable {
        let authorName: String?
        let authorURL: URL?
        let html: String
        let thumbnailURL: URL?
        let publishedAt: Date?

        enum CodingKeys: String, CodingKey {
            case authorName = "author_name"
            case authorURL = "author_url"
            case html
            case thumbnailURL = "thumbnail_url"
            case publishedAtText = "published_at"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            authorName = try c.decodeIfPresent(String.self, forKey: .authorName)
            authorURL = URL(string: try c.decodeIfPresent(String.self, forKey: .authorURL) ?? "")
            html = try c.decode(String.self, forKey: .html)
            thumbnailURL = URL(string: try c.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? "")
            let rawDate = try c.decodeIfPresent(String.self, forKey: .publishedAtText)
            if let rawDate {
                publishedAt = ISO8601DateFormatter().date(from: rawDate)
            } else {
                publishedAt = nil
            }
        }
    }

    private func fetchOEmbed(for url: URL) async throws -> OEmbedResponse {
        var components = URLComponents(url: Self.oEmbedEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString),
            URLQueryItem(name: "omit_script", value: "1"),
            URLQueryItem(name: "hide_thread", value: "1"),
            URLQueryItem(name: "dnt", value: "1")
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("WebsiteCommander/experimental-blog", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw XPostImportError.cancelled
        } catch {
            throw Self.mapNetworkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw XPostImportError.malformedResponse }
        if (500...599).contains(http.statusCode) { throw XPostImportError.xServiceUnavailable }
        guard (200..<300).contains(http.statusCode) else { throw XPostImportError.unavailablePost }
        guard data.count <= 2 * 1024 * 1024 else { throw XPostImportError.malformedResponse }
        do {
            return try JSONDecoder().decode(OEmbedResponse.self, from: data)
        } catch {
            throw XPostImportError.malformedResponse
        }
    }

    private static func mapNetworkError(_ error: Error) -> XPostImportError {
        if let xError = error as? XPostImportError { return xError }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return .cancelled }
            return .networkUnavailable
        }
        return .networkUnavailable
    }

    private static func authorHandle(from url: URL?) -> String? {
        guard let url, let first = url.path.split(separator: "/").first else { return nil }
        let handle = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return handle.isEmpty ? nil : handle
    }

    // MARK: Image safety

    private struct DownloadedImage {
        let data: Data
        let mimeType: String
        let width: Int
        let height: Int
        let `extension`: String
        let sha256: String
    }

    private actor ImageDownloadBudget {
        private var total = 0

        func reserve(_ bytes: Int) throws {
            guard bytes >= 0, total + bytes <= XPostImporter.maxTotalImageBytes else {
                throw XPostImportError.malformedResponse
            }
            total += bytes
        }
    }

    private enum DownloadResult {
        case success(DownloadedImage)
        case failure(Error)
    }

    private func downloadImages(_ urls: [URL], sessionID: UUID) async -> [DownloadResult] {
        guard !urls.isEmpty else { return [] }
        let budget = ImageDownloadBudget()
        var results: [DownloadResult] = []
        var index = 0
        while index < urls.count {
            let batch = Array(urls[index..<min(index + 2, urls.count)])
            let batchResults = await withTaskGroup(of: DownloadResult.self, returning: [DownloadResult].self) { group in
                for url in batch {
                    group.addTask { [weak self] in
                        guard let self else { return .failure(XPostImportError.cancelled) }
                        do { return .success(try await self.downloadImage(url, budget: budget)) }
                        catch { return .failure(error) }
                    }
                }
                var collected: [DownloadResult] = []
                for await result in group { collected.append(result) }
                return collected
            }
            results.append(contentsOf: batchResults)
            index += batch.count
        }
        return results
    }

    private func downloadImage(_ url: URL, budget: ImageDownloadBudget) async throws -> DownloadedImage {
        guard Self.isDirectOfficialImageURL(url) else { throw XPostImportError.unsupportedURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration,
                                  delegate: XImageRedirectDelegate(), delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw XPostImportError.cancelled
        } catch {
            throw XPostImportError.networkUnavailable
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let mime = http.mimeType?.lowercased(), mime.hasPrefix("image/") else {
            throw XPostImportError.malformedResponse
        }
        let contentLength = response.expectedContentLength
        if contentLength > Int64(Self.maxImageBytes) {
            throw AssetStoreError.assetTooLarge
        }

        var data = Data()
        if contentLength > 0 {
            data.reserveCapacity(min(Self.maxImageBytes, Int(contentLength)))
        }
        var chunk: [UInt8] = []
        chunk.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count >= 64 * 1024 {
                guard data.count + chunk.count <= Self.maxImageBytes else { throw AssetStoreError.assetTooLarge }
                try await budget.reserve(chunk.count)
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            guard data.count + chunk.count <= Self.maxImageBytes else { throw AssetStoreError.assetTooLarge }
            try await budget.reserve(chunk.count)
            data.append(contentsOf: chunk)
        }
        return try normalizeImage(data, mimeType: mime)
    }

    private static func isDirectOfficialImageURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "pbs.twimg.com",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.path.hasPrefix("/media/") else { return false }
        let lower = url.path.lowercased()
        return !lower.hasSuffix(".mp4") && !lower.hasSuffix(".m3u8")
    }

    private func normalizeImage(_ data: Data, mimeType: String) throws -> DownloadedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              Int64(width) * Int64(height) <= 40_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XPostImportError.malformedResponse
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw XPostImportError.malformedResponse
        }
        // Re-encoding to PNG strips source metadata and prevents an imported
        // EXIF payload from being copied into the repository.
        CGImageDestinationAddImage(destination, image, [:] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XPostImportError.malformedResponse }
        let normalized = output as Data
        let digest = SHA256.hash(data: normalized).map { String(format: "%02x", $0) }.joined()
        _ = mimeType
        return DownloadedImage(data: normalized, mimeType: "image/png", width: width,
                               height: height, extension: "png", sha256: digest)
    }
}

// MARK: HTML extraction

private enum XPostHTMLParser {
    struct Result {
        let text: String
        let mediaURLs: [URL]
        let hasMedia: Bool
        let hasVideo: Bool
    }

    static func parse(_ html: String) throws -> Result {
        let paragraphRegex = try! NSRegularExpression(pattern: #"(?is)<p\b[^>]*>(.*?)</p\s*>"#)
        guard let match = paragraphRegex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = match.range(at: 1) as NSRange?,
              let swiftRange = Range(range, in: html) else {
            throw XPostImportError.malformedResponse
        }
        var fragment = String(html[swiftRange])
        fragment = fragment.replacingOccurrences(of: #"(?is)<script\b[^>]*>.*?</script\s*>"#, with: "", options: .regularExpression)
        fragment = fragment.replacingOccurrences(of: #"(?is)<style\b[^>]*>.*?</style\s*>"#, with: "", options: .regularExpression)
        fragment = fragment.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        let wrapped = "<div>\(fragment)</div>"
        guard let attributed = try? NSAttributedString(
            data: Data(wrapped.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil) else {
            throw XPostImportError.malformedResponse
        }
        let text = attributed.string
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XPostImportError.emptyPost }

        let attributes = try? NSRegularExpression(pattern: #"(?i)(?:href|src)\s*=\s*["']([^"']+)["']"#)
        let matches = attributes?.matches(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)) ?? []
        let urls = matches.compactMap { match -> URL? in
            guard let range = Range(match.range(at: 1), in: fragment) else { return nil }
            return URL(string: String(fragment[range]))
        }
        let lower = html.lowercased()
        let hasVideo = lower.contains("<video") || lower.contains("video.twimg.com") ||
            lower.contains(".mp4") || lower.contains(".m3u8")
        let hasMedia = !urls.isEmpty || hasVideo || lower.contains("pbs.twimg.com") || lower.contains("thumbnail")
        return Result(text: text, mediaURLs: urls, hasMedia: hasMedia, hasVideo: hasVideo)
    }
}

private final class XEmbedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirectCount = 0

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectCount += 1
        guard redirectCount <= 3, let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "publish.x.com",
              url.path == "/oembed" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class XImageRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirectCount = 0

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectCount += 1
        guard redirectCount <= 3, let url = request.url,
              XPostImporter.isDirectOfficialImageURLForRedirect(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private extension XPostImporter {
    static func isDirectOfficialImageURLForRedirect(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "pbs.twimg.com",
              url.port == nil || url.port == 443,
              url.user == nil,
              url.path.hasPrefix("/media/") else { return false }
        return true
    }
}
