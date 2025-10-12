import Foundation

func configureGlobalURLCache(memoryMB: Int = 64, diskMB: Int = 200) {
    let mem = memoryMB * 1024 * 1024
    let disk = diskMB * 1024 * 1024
    URLCache.shared = URLCache(
        memoryCapacity: mem,
        diskCapacity: disk,
        diskPath: "ImageCache"
    )
}
