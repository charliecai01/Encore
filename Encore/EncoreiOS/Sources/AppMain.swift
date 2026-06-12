import UIKit
import SwiftUI
import AVFAudio
import EncoreCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Background audio: required for playback to continue when the app is
        // backgrounded and for CarPlay's Now Playing surface.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)

        if let saved = UserDefaults.standard.string(forKey: "lyricsProvider"),
           let provider = LyricsService.Provider(rawValue: saved) {
            LyricsService.shared.preferred = provider
        }
        URLCache.shared = URLCache(memoryCapacity: 128 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
        return true
    }
}

final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: MobileRoot())
        window.overrideUserInterfaceStyle = .dark
        self.window = window
        window.makeKeyAndVisible()
        Task { await AuthManager.shared.bootstrap() }
    }
}
