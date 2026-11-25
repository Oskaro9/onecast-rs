import AuthenticationServices
import Foundation
import OneCastCore
import Security

/// Persists and loads the serialized `AuthBundle` in the macOS Keychain.
enum KeychainStore {
    private static let service = "com.onecastoss.macos.auth"
    private static let account = "default"

    static func save(_ bundle: AuthBundle) {
        let dict: [String: Any] = [
            "oauthAccessToken": bundle.oauthAccessToken,
            "oauthRefreshToken": bundle.oauthRefreshToken,
            "xstsToken": bundle.xstsToken,
            "userHash": bundle.userHash,
            "gsToken": bundle.gsToken,
            "expiresInSecs": bundle.expiresInSecs
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributesToUpdate: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    static func load() -> AuthBundle? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccess = dict["oauthAccessToken"] as? String,
              let oauthRefresh = dict["oauthRefreshToken"] as? String,
              let xsts = dict["xstsToken"] as? String,
              let uhs = dict["userHash"] as? String,
              let gs = dict["gsToken"] as? String,
              let expires = dict["expiresInSecs"] as? UInt64
        else {
            return nil
        }

        return AuthBundle(
            oauthAccessToken: oauthAccess,
            oauthRefreshToken: oauthRefresh,
            xstsToken: xsts,
            userHash: uhs,
            gsToken: gs,
            expiresInSecs: expires
        )
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Manages Microsoft OAuth sign-in and Xbox Live token refresh.
@MainActor
final class AuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var bundle: AuthBundle?
    @Published var isAuthenticating = false
    @Published var errorMessage: String?

    private let core: OneCastCore
    private var webAuthSession: ASWebAuthenticationSession?

    init(core: OneCastCore) {
        self.core = core
        super.init()
        self.bundle = KeychainStore.load()
    }

    func signIn() {
        guard let url = URL(string: core.oauthAuthorizeUrl()) else { return }
        isAuthenticating = true
        errorMessage = nil

        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "https"
        ) { [weak self] callbackURL, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAuthenticating = false

                if let error {
                    self.errorMessage = error.localizedDescription
                    return
                }
                guard let redirect = callbackURL?.absoluteString else {
                    self.errorMessage = "No redirect URL received"
                    return
                }

                await self.completeLogin(redirectURL: redirect)
            }
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.webAuthSession = session
        session.start()
    }

    func completeLogin(redirectURL: String) async {
        isAuthenticating = true
        errorMessage = nil
        do {
            let coreRef = self.core
            let newBundle = try await Task.detached(priority: .userInitiated) {
                try coreRef.loginWithRedirectUrl(redirectUrl: redirectURL)
            }.value
            self.bundle = newBundle
            KeychainStore.save(newBundle)
        } catch {
            self.errorMessage = error.localizedDescription
        }
        isAuthenticating = false
    }

    func refreshIfNeeded() async {
        guard let refreshToken = bundle?.oauthRefreshToken, !refreshToken.isEmpty else { return }
        do {
            let coreRef = self.core
            let refreshed = try await Task.detached(priority: .userInitiated) {
                try coreRef.refreshAuth(refreshToken: refreshToken)
            }.value
            self.bundle = refreshed
            KeychainStore.save(refreshed)
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        bundle = nil
        KeychainStore.clear()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
