import SwiftUI

// MARK: - Main Content View
struct ContentView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @ObservedObject private var audioPlayer = AudioPlayer.shared

    @State private var showNowPlaying = false

    var body: some View {
        Group {
            if apiService.isLoggedIn {
                if #available(iOS 16.0, *) { // NOTE: Changed from 26.0 to 16.0 as TabView with accessory is iOS 16+
                    TabScaffold(showNowPlaying: $showNowPlaying)
                        .environmentObject(apiService)
                        .environmentObject(audioPlayer) // <-- ADDED
                        .fullScreenCover(isPresented: $showNowPlaying) {
                            NowPlayingView(onDismiss: { showNowPlaying = false })
                                .environmentObject(apiService)
                                .environmentObject(audioPlayer)
                                // Optional (iOS 17+): avoid the black backdrop while swiping
                                .presentationBackground(.clear)
                        }

                } else {
                    Text("This app requires iOS 16 or later.")
                }
            } else {
                LoginView().environmentObject(apiService)
            }
        }
    }
}

// MARK: - Native TabView Scaffold (iOS 16+)
@available(iOS 16.0, *)
private struct TabScaffold: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @EnvironmentObject var audioPlayer: AudioPlayer

    @Binding var showNowPlaying: Bool
    @State private var searchText = ""

    var body: some View {
        if #available(iOS 26.0, *) {
            TabView {
                // Home
                Tab("Home", systemImage: "house.fill") {
                    NavigationStack {
                        HomeView()
                            .environmentObject(apiService)
                            .navigationTitle("Home")
                    }
                }

                // New
                Tab("New", systemImage: "square.grid.2x2.fill") {
                    NavigationStack {
                        NewView()
                            .navigationTitle("New")
                    }
                }

                // Radio
                Tab("Radio", systemImage: "dot.radiowaves.left.and.right") {
                    NavigationStack {
                        RadioView()
                            .navigationTitle("Radio")
                    }
                }

                // Library  (← now also receives DownloadsAPI)
                Tab("Library", systemImage: "music.note.square.stack.fill") {
                    NavigationStack {
                        LibraryView()
                            .environmentObject(apiService)
                            .environmentObject(DownloadsAPI.shared)
                            .navigationTitle("Library")
                    }
                }

                // Search
                Tab(role: .search) {
                    NavigationStack {
                        SearchView()
                            .environmentObject(apiService)
                            .environmentObject(DownloadsAPI.shared)
                            .navigationTitle("Search")
                    }
                }
            }
            .tint(Color(red: 0.95, green: 0.20, blue: 0.30))
            .tabViewBottomAccessory {
                MiniPlayerView()
                    .environmentObject(apiService)
                    .environmentObject(audioPlayer)
            }
            .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            // Fallback on earlier versions
        }
    }
}
