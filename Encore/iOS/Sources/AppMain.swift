import UIKit
import SwiftUI
import AVFAudio
import EncoreCore

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// Orientations currently allowed. The app is portrait-only, except the
    /// podcast video screen flips this to landscape while it's presented
    /// (Info.plist declares all orientations; this mask is the actual gate).
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }

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

/// Flip the allowed orientations at runtime and rotate to match (iOS 16+).
@MainActor
enum OrientationLock {
    static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
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

    // Snapshot playback position when leaving the app so reopening resumes at the
    // right spot even if iOS terminates us in the background.
    func sceneWillResignActive(_ scene: UIScene) {
        PlayerEngine.shared.persistSnapshot()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        PlayerEngine.shared.persistSnapshot()
    }
}
