import SwiftUI
import Combine

// MARK: - Color Extension for Apple Music Red
extension Color {
    // Custom color property for the vibrant Apple Music red
    static let appTint = Color(red: 1.0, green: 0.17, blue: 0.33) // Hex #FF2C55
}

// MARK: - 1. VIEW MODEL (Logic)
class LoginViewModel: ObservableObject {
    @Published var serverURL: String = ""
    @Published var username: String = ""
    @Published var password: String = ""
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    
    // Check if both username and password fields have content
    @Published var isLoginEnabled: Bool = false

    // NOTE: JellyfinAPIService must be defined elsewhere in your project
    private var apiService: JellyfinAPIService 
    private var cancellables = Set<AnyCancellable>()
    
    init(apiService: JellyfinAPIService) {
        self.apiService = apiService
        
        // Load saved server URL
        if let savedURL = UserDefaults.standard.string(forKey: "jellyfinServer") {
            self.serverURL = savedURL
        }
        
        // Setup validation subscription to enable/disable the Login button
        $username.combineLatest($password, $serverURL)
            .map { username, password, serverURL in
                // Login button is enabled only if all fields are non-empty
                !username.isEmpty && !password.isEmpty && !serverURL.isEmpty
            }
            .assign(to: &$isLoginEnabled)
    }
    
    func login() {
        isLoading = true
        errorMessage = nil
        
        // Save the server URL for next time
        UserDefaults.standard.set(serverURL, forKey: "jellyfinServer")
        
        apiService.login(username: username, password: password, serverUrl: serverURL)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] completion in
                self?.isLoading = false
                if case .failure(let error) = completion {
                    self?.errorMessage = "Login failed: \(error.localizedDescription)"
                }
            } receiveValue: { _ in
                // Login successful; API Service handles state update
            }
            .store(in: &cancellables)
    }
}


// MARK: - Custom Component for Styled Input Field
struct CustomLoginField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var keyboardType: UIKeyboardType = .default
    
    var body: some View {
        // ZStack used to place the placeholder text inside the rounded background
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 30)
                // Use ultraThinMaterial for a modern, system-aware, slightly transparent background
                .fill(.ultraThinMaterial) 
                .frame(height: 60)
                .overlay(
                    // Overlay for the subtle border that contrasts with the background
                    RoundedRectangle(cornerRadius: 30)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
            
            if isSecure {
                SecureField("", text: $text)
                    .foregroundColor(.primary) // Automatically adapts to light/dark text color
                    .autocapitalization(.none)
                    .padding(.horizontal, 25)
                    .placeholder(when: text.isEmpty) {
                        Text(placeholder)
                            .foregroundColor(.appTint) // Placeholder is now red
                            .padding(.leading, 25)
                    }
            } else {
                TextField("", text: $text)
                    .foregroundColor(.primary) // Automatically adapts to light/dark text color
                    .autocapitalization(.none)
                    .keyboardType(keyboardType)
                    .padding(.horizontal, 25)
                    .placeholder(when: text.isEmpty) {
                        Text(placeholder)
                            .foregroundColor(.appTint) // Placeholder is now red
                            .padding(.leading, 25)
                    }
            }
        }
    }
}

// Extension to allow custom placeholder styling
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content) -> some View {
        
        ZStack(alignment: alignment) {
            content().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}


// MARK: - 2. VIEW (UI)
struct LoginView: View {
    // We use @Environment to read the current color scheme
    @Environment(\.colorScheme) var colorScheme 
    @EnvironmentObject var apiService: JellyfinAPIService
    
    @StateObject private var viewModel: LoginViewModel
    
    init() {
        _viewModel = StateObject(wrappedValue: LoginViewModel(apiService: JellyfinAPIService.shared))
    }
    
    var body: some View {
        ZStack {
            // 1. Background: Using a system-aware color ensures light mode is white and dark mode is black/dark grey
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            
            // 2. Content
            VStack(spacing: 20) {
                
                // App Title / Logo Area
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list") 
                        .font(.system(size: 80))
                        .foregroundColor(.appTint) // Icon color is now red
                    
                    Text("Jelly Player")
                        .font(.title)
                        .fontWeight(.heavy)
                        .foregroundColor(.primary) 
                }
                .padding(.bottom, 40)
                
                // Input Fields
                VStack(spacing: 15) {
                    CustomLoginField(
                        placeholder: "Jellyfin Server URL",
                        text: $viewModel.serverURL,
                        keyboardType: .URL
                    )
                    
                    CustomLoginField(
                        placeholder: "USERNAME",
                        text: $viewModel.username
                    )
                    
                    CustomLoginField(
                        placeholder: "PASSWORD",
                        text: $viewModel.password,
                        isSecure: true
                    )
                }
                .padding(.horizontal, 20)
                
                // Login Button
                if viewModel.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .appTint)) // Loading spinner is now red
                        .frame(width: 60, height: 60)
                        .padding(.top, 30)
                } else {
                    Button(action: { viewModel.login() }) {
                        Text("LOGIN")
                            .font(.system(.headline, design: .rounded))
                            .fontWeight(.bold)
                            .foregroundColor(.white) // Keep text white for contrast on the solid button
                            .frame(maxWidth: 250)
                            .frame(height: 60)
                            .background(
                                RoundedRectangle(cornerRadius: 30)
                                    // Button is now solid red
                                    .fill(Color.appTint)
                                    .shadow(color: Color.appTint.opacity(colorScheme == .dark ? 0.8 : 0.3), radius: 10, x: 0, y: 5)
                            )
                    }
                    .padding(.top, 30)
                    .disabled(!viewModel.isLoginEnabled)
                    .opacity(viewModel.isLoginEnabled ? 1.0 : 0.6)
                }
                
                // Error Message
                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 10)
                }
                
                Spacer() // Pushes content up
            }
            .padding(.top, 80)
            .padding(.bottom, 20)
        }
    }
}
