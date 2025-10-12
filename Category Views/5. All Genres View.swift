import SwiftUI
import Combine
import UIKit

struct AllGenresView: View {
    @EnvironmentObject var apiService: JellyfinAPIService
    @Environment(\.dismiss) private var dismiss

    // Data
    @State private var genresRaw: [JellyfinGenre] = []
    @State private var filtered: [JellyfinGenre] = []
    @State private var searchText: String = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var cancellables = Set<AnyCancellable>()

    // UI
    private let horizontalPad: CGFloat = 20
    private let rowVPad: CGFloat = 12

    var body: some View {
        Group {
            if isLoading {
                VStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                VStack { Spacer(); Text(errorMessage).foregroundColor(.red); Spacer() }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Reduced spacer for tighter spacing under the search bar
                        Spacer().frame(height: 2) // Changed from 8 to 2

                        // List (simple rows, no covers)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered, id: \.id) { genre in
                                NavigationLink {
                                    GenreDetailView(genre: genre)
                                        .environmentObject(apiService)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(genre.name)
                                            .font(.system(size: 16, weight: .regular))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, horizontalPad)
                                    .padding(.vertical, rowVPad)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Divider()
                                    .padding(.leading, horizontalPad)
                            }
                        }

                        // Space for your floating mini-player/menu
                        Color.clear.frame(height: 120)
                    }
                    .padding(.top, 2) // Reduced from 8 to 4
                }
                .scrollIndicators(.automatic)
            }
        }
        .navigationTitle("Genres")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.automatic, for: .navigationBar)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .automatic),
            prompt: "Search genres"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .onChange(of: searchText) { _ in
            applySearch()
        }
        .onAppear { fetchGenres() }
    }

    // MARK: - Data
    private func fetchGenres() {
        isLoading = true
        errorMessage = nil

        apiService.fetchGenres()
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { completion in
                isLoading = false
                if case .failure(let error) = completion {
                    errorMessage = "Failed to load genres: \(error.localizedDescription)"
                }
            }, receiveValue: { genres in
                self.genresRaw = genres.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                self.applySearch()
            })
            .store(in: &cancellables)
    }

    private func applySearch() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            filtered = genresRaw
            return
        }
        filtered = genresRaw.filter { $0.name.lowercased().contains(q) }
    }
}
