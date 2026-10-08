import AppKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct CloudBranding: Decodable {
    let siteName: String
    let logoUrl: String
    let faviconUrl: String

    static let maximumImageBytes = 1_048_576

    static func endpoint(_ raw: String) throws -> URL {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = base.lowercased().hasPrefix("http") ? base : "https://\(base)"
        guard let url = URL(string: normalized + "/api/branding"),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BrandingError.invalidURL
        }
        return url
    }

    static func decode(_ data: Data, status: Int) throws -> CloudBranding {
        if status == 404 { throw BrandingError.updateWorker }
        guard status == 200 else { throw BrandingError.server(status) }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    static func saveRequest(
        credentials: CloudCredentials, siteName: String,
        logo: CloudBrandingImage?, favicon: CloudBrandingImage?,
        clearLogo: Bool, clearFavicon: Bool
    ) throws -> URLRequest {
        guard credentials.isConfigured else { throw BrandingError.notConfigured }
        let name = siteName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.unicodeScalars.count <= 80 else { throw BrandingError.nameTooLong }
        let boundary = UUID().uuidString
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for (key, value) in [("siteName", name), ("clearLogo", clearLogo ? "true" : "false"),
                             ("clearFavicon", clearFavicon ? "true" : "false")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        for (key, image) in [("logo", logo), ("favicon", favicon)] {
            guard let image else { continue }
            guard !image.data.isEmpty, image.data.count <= maximumImageBytes else {
                throw BrandingError.imageTooLarge
            }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"; filename=\"\(key).\(image.fileExtension)\"\r\nContent-Type: \(image.contentType)\r\n\r\n")
            body.append(image.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        var request = URLRequest(url: try endpoint(credentials.workerURL))
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.uploadToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    // Never forward the Bearer token to image URLs supplied by a server.
    static func imageURL(_ path: String, endpoint: URL) -> URL? {
        guard let url = URL(string: path, relativeTo: endpoint)?.absoluteURL,
              url.scheme == endpoint.scheme, url.host == endpoint.host,
              url.port == endpoint.port else { return nil }
        return url
    }

    static func preview(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        var size = NSSize(width: image.width, height: image.height)
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapsAxes = (5...8).contains(orientation)
            // Thumbnail transforms honor DPI; share-page previews fit the oriented pixel canvas.
            size = NSSize(width: swapsAxes ? height.doubleValue : width.doubleValue,
                          height: swapsAxes ? width.doubleValue : height.doubleValue)
        }
        return NSImage(cgImage: image, size: size)
    }

    static func thumbnail(_ data: Data) async -> NSImage? {
        if let image = preview(data) { return image }
        guard String(data: data, encoding: .utf8)?.contains("<svg") == true else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("svg")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try data.write(to: url)
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 48, height: 48), scale: 2,
                representationTypes: .thumbnail
            )
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return NSImage(cgImage: representation.cgImage, size: .zero)
        } catch { return nil }
    }

    static func read(_ request: URLRequest, limit: Int) async throws -> (Data, Int) {
        let (bytes, response) = try await URLSession.shared.bytes(
            for: request, delegate: request.value(forHTTPHeaderField: "Authorization") == nil ? nil : BrandingNoRedirect()
        )
        guard let http = response as? HTTPURLResponse else { throw BrandingError.invalidResponse }
        if http.statusCode == 404 { throw BrandingError.updateWorker }
        guard response.expectedContentLength <= Int64(limit) else { throw BrandingError.imageTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw BrandingError.imageTooLarge }
            data.append(byte)
        }
        return (data, http.statusCode)
    }
}

struct CloudBrandingImage {
    let data: Data
    let fileExtension: String
    let contentType: String
    let filename: String
    let isSquare: Bool?

    init(url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= CloudBranding.maximumImageBytes else { throw BrandingError.imageTooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: CloudBranding.maximumImageBytes + 1) ?? Data()
        guard data.count <= CloudBranding.maximumImageBytes else { throw BrandingError.imageTooLarge }
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let identifier = source.flatMap { CGImageSourceGetType($0) }.map { $0 as String }
        let formats = [UTType.png.identifier: ("png", "image/png"),
                       UTType.jpeg.identifier: ("jpg", "image/jpeg"),
                       UTType(filenameExtension: "ico")!.identifier: ("ico", "image/x-icon")]
        // Some sites' favicon.ico files are PNGs. Send the actual image type.
        guard let format = identifier.flatMap({ formats[$0] })
            ?? (ext == "svg" ? ("svg", "image/svg+xml") : nil) else {
            throw BrandingError.invalidImage
        }
        self.data = data
        self.fileExtension = format.0
        self.contentType = format.1
        self.filename = url.lastPathComponent
        if let source,
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber {
            isSquare = width == height
        } else if let size = NSImage(data: data)?.size, size.width > 0, size.height > 0 {
            isSquare = size.width == size.height
        } else {
            isSquare = nil
        }
    }
}

enum BrandingError: LocalizedError {
    case invalidURL, notConfigured, invalidResponse, updateWorker, nameTooLong, invalidImage, imageTooLarge
    case server(Int)
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Enter a valid Worker URL."
        case .notConfigured: "Configure your Worker and upload token first."
        case .invalidResponse: "The Worker returned an invalid response."
        case .updateWorker: "Update your Worker to change branding"
        case .nameTooLong: "Site name must be at most 80 characters."
        case .invalidImage: "Choose a PNG, JPEG, SVG or ICO image."
        case .imageTooLarge: "Each image must be at most 1 MiB."
        case .server(let status): "The Worker could not save or load branding (HTTP \(status))."
        }
    }
}

private final class BrandingNoRedirect: NSObject, URLSessionTaskDelegate {
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@Observable
final class CloudBrandingModel {
    var siteName = "Screendrop"
    var logo: CloudBrandingImage?
    var favicon: CloudBrandingImage?
    var clearLogo = false
    var clearFavicon = false
    var logoPreview: NSImage?
    var faviconPreview: NSImage?
    var hasLogo = false
    var hasFavicon = false
    var isBusy = false
    var isReady = false
    var needsUpdate = false
    var message: String?
    private var generation = UUID()
    private var loadedEndpoint: URL?

    func load(workerURL: String) async {
        generation = UUID()
        let current = generation
        isReady = false
        isBusy = false
        loadedEndpoint = nil
        needsUpdate = false
        message = nil
        logo = nil
        favicon = nil
        logoPreview = nil
        faviconPreview = nil
        clearLogo = false
        clearFavicon = false
        guard !workerURL.isEmpty else { return }
        isBusy = true
        defer { if current == generation { isBusy = false } }
        do {
            let endpoint = try CloudBranding.endpoint(workerURL)
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 15
            let (data, status) = try await CloudBranding.read(request, limit: 16_384)
            let values = try CloudBranding.decode(data, status: status)
            try Task.checkCancellation()
            guard current == generation else { return }
            await apply(values, endpoint: endpoint, generation: current)
        } catch is CancellationError {
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            needsUpdate = (error as? BrandingError) == .updateWorker
            message = error.localizedDescription
        }
    }

    func save() async {
        guard isReady, !isBusy else { return }
        let current = generation
        isBusy = true
        message = nil
        defer { if current == generation { isBusy = false } }
        do {
            let request = try CloudBranding.saveRequest(
                credentials: CloudCredentialStore.shared.snapshot(), siteName: siteName,
                logo: logo, favicon: favicon, clearLogo: clearLogo, clearFavicon: clearFavicon
            )
            guard request.url == loadedEndpoint else { throw BrandingError.invalidResponse }
            let (data, status) = try await CloudBranding.read(request, limit: 16_384)
            let values = try CloudBranding.decode(data, status: status)
            guard current == generation else { return }
            await apply(values, endpoint: request.url!, generation: current)
            if current == generation { message = "Saved" }
        } catch {
            guard current == generation else { return }
            needsUpdate = (error as? BrandingError) == .updateWorker
            message = error.localizedDescription
        }
    }

    private func apply(_ values: CloudBranding, endpoint: URL, generation current: UUID) async {
        loadedEndpoint = endpoint
        siteName = values.siteName
        logo = nil
        favicon = nil
        clearLogo = false
        clearFavicon = false
        hasLogo = values.logoUrl.contains("/api/branding/logo")
        hasFavicon = values.faviconUrl.contains("/api/branding/favicon")
        isReady = true
        for (kind, path) in [("logo", values.logoUrl), ("favicon", values.faviconUrl)] {
            guard let url = CloudBranding.imageURL(path, endpoint: endpoint) else { continue }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = 10
            let result = try? await CloudBranding.read(request, limit: CloudBranding.maximumImageBytes)
            guard current == generation, !Task.isCancelled else { return }
            let preview = if let result, result.1 == 200 {
                await CloudBranding.thumbnail(result.0)
            } else { NSImage?.none }
            guard current == generation, !Task.isCancelled else { return }
            if kind == "logo" { logoPreview = preview } else { faviconPreview = preview }
        }
    }
}

extension BrandingError: Equatable {}

struct CloudBrandingSettingsGroup: View {
    let workerURL: String
    @State var model = CloudBrandingModel()
    @State private var choosingLogo = true
    @State private var isChoosingImage = false

    var body: some View {
        Section {
            if model.needsUpdate {
                Text("Update your Worker to change branding")
                    .foregroundStyle(.secondary)
            } else if workerURL.isEmpty {
                Text("Configure a Worker above to customize the share page.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Site name", text: $model.siteName)
                    .textFieldStyle(.roundedBorder)
                imageRow("Logo", isLogo: true)
                imageRow("Favicon", isLogo: false)
                HStack {
                    if model.isBusy { ProgressView().controlSize(.small) }
                    if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.isReady || model.isBusy)
                }
            }
        } header: {
            Text("Share page")
        } footer: {
            Text("PNG, JPEG, SVG or ICO, up to 1 MiB each. With no favicon, the logo is used. Clear both to use the default images; leave the site name empty for the default name.")
        }
        .disabled(model.isBusy)
        .task(id: workerURL) { await model.load(workerURL: workerURL) }
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.png, .jpeg, .svg, UTType(filenameExtension: "ico")!]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let image = try CloudBrandingImage(url: url)
                let isLogo = choosingLogo
                if isLogo { model.logo = image; model.clearLogo = false; model.logoPreview = nil }
                else { model.favicon = image; model.clearFavicon = false; model.faviconPreview = nil }
                Task {
                    let preview = await CloudBranding.thumbnail(image.data)
                    if isLogo, model.logo?.data == image.data { model.logoPreview = preview }
                    if !isLogo, model.favicon?.data == image.data { model.faviconPreview = preview }
                }
                model.message = nil
            } catch { model.message = error.localizedDescription }
        }
    }

    private func imageRow(_ title: String, isLogo: Bool) -> some View {
        let pending = isLogo ? model.logo : model.favicon
        let clearing = isLogo ? model.clearLogo : model.clearFavicon
        let usesLogo = !isLogo && (clearing || (pending == nil && !model.hasFavicon))
        let preview = usesLogo ? (model.clearLogo ? nil : model.logoPreview)
            : (clearing ? nil : (isLogo ? model.logoPreview : model.faviconPreview))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(title).frame(width: 80, alignment: .leading)
                Group {
                    if let preview {
                        // Not scaledToFit: fit the pixel proportions, and check wide, tall and square renders when changing it.
                        Image(nsImage: preview).resizable().aspectRatio(preview.size, contentMode: .fit)
                    }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
                .frame(width: 32, height: 32)
                .accessibilityLabel("\(title) preview")
                Text(pending?.filename ?? (usesLogo ? "Logo / default" : (clearing ? "Default" : "Current")))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") { choosingLogo = isLogo; isChoosingImage = true }
                    .accessibilityLabel("Choose \(title.lowercased())")
                Button("Clear") {
                    if isLogo { model.logo = nil; model.clearLogo = true }
                    else { model.favicon = nil; model.clearFavicon = true }
                }
                .disabled(clearing || (pending == nil && !(isLogo ? model.hasLogo : model.hasFavicon)))
                .accessibilityLabel("Clear \(title.lowercased())")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(isLogo ? "Square logo, at least 96 × 96 px (PNG or SVG)."
                     : "Square favicon, 48 × 48 px (PNG or ICO).")
                if pending?.isSquare == false {
                    Text("This image isn’t square; it will be scaled to fit.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 92)
        }
        .disabled(!model.isReady)
    }
}
