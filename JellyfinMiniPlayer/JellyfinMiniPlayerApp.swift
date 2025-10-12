import SwiftUI

@main
struct JellyfinMiniPlayerApp: App {
    @StateObject private var apiService = JellyfinAPIService.shared
    @StateObject private var downloads = DownloadsAPI.shared

    init() {
        // 1) Configure shared caches (disk + memory)
        configureGlobalURLCache(memoryMB: 64, diskMB: 200)

        // 2) Your existing setup
        let api = JellyfinAPIService.shared
        api.checkForSavedCredentials()
        DownloadsAPI.shared.session = api
        DownloadsAPI.shared.prepareDownloadsFolderIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(apiService)
                .environmentObject(downloads)
        }
    }
}
