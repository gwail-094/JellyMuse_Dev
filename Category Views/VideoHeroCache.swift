import Foundation

func cachedPosterURL(for remoteURL: URL, albumId: String) -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    // Keep mp4 extension; name by album id
    return caches.appendingPathComponent("poster-\(albumId).mp4")
}

func ensurePosterCached(remoteURL: URL, albumId: String, completion: @escaping (URL?) -> Void) {
    let dst = cachedPosterURL(for: remoteURL, albumId: albumId)
    if FileManager.default.fileExists(atPath: dst.path) {
        completion(dst)
        return
    }

    URLSession.shared.downloadTask(with: remoteURL) { tmp, _, _ in
        guard let tmp else { DispatchQueue.main.async { completion(nil) }; return }
        do {
            // Remove old if any (paranoid)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: tmp, to: dst)
            DispatchQueue.main.async { completion(dst) }
        } catch {
            DispatchQueue.main.async { completion(nil) }
        }
    }.resume()
}
