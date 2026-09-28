import Foundation
import CryptoKit

/// A manifest sits beside the files it lists, e.g. in a pinned HF `resolve/<revision>/` directory.
public struct DownloadManifest: Codable, Sendable {
    public struct File: Codable, Sendable {
        public let path: String
        public let sha256: String
        public let bytes: Int64
    }
    public let formatVersion: Int
    public let name: String
    public let files: [File]
}

public actor ModelDownloader {
    public init() {}
    private func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func validate(_ manifest: DownloadManifest) throws {
        guard manifest.formatVersion == 1, !manifest.files.isEmpty, manifest.files.count <= 10_000 else {
            throw SBV2Error.invalidModel("Unsupported or empty download manifest")
        }
        var paths = Set<String>()
        for file in manifest.files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !file.path.contains("\\"), !file.path.contains(":"),
                  !file.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  file.bytes >= 0, file.bytes <= 8 * 1024 * 1024 * 1024,
                  file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  paths.insert(file.path).inserted else {
                throw SBV2Error.invalidModel("Invalid download entry: \(file.path)")
            }
        }
    }
    public func install(manifestURL: URL, destination: URL,
                        progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws {
        guard manifestURL.scheme == "https" else { throw SBV2Error.invalidModel("Use an HTTPS manifest URL") }
        let (data, response) = try await URLSession.shared.data(from: manifestURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https", data.count <= 4 * 1024 * 1024 else {
            throw SBV2Error.invalidModel("Could not download model manifest")
        }
        let manifest = try JSONDecoder().decode(DownloadManifest.self, from: data)
        try Self.validate(manifest)
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { throw SBV2Error.invalidModel("Destination already exists; select a new folder") }
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
        try manager.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: stage) }
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            let remote = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.path)
            let (temporary, response) = try await URLSession.shared.download(from: remote)
            defer { try? manager.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https",
                  (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(entry.bytes),
                  try hash(temporary) == entry.sha256 else {
                throw SBV2Error.invalidModel("Checksum or download failed: \(entry.path)")
            }
            let output = stage.appendingPathComponent(entry.path)
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.moveItem(at: temporary, to: output)
            await progress(index + 1, manifest.files.count)
        }
        try manager.moveItem(at: stage, to: destination)
    }
}
