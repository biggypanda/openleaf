import UIKit

/// Son açılan defter ve her defterde kalınan sayfa. Yalnızca bu iPad'de tutulur, yedeğe girmez.
enum LastOpened {
    private static let pagesKey = "son.sayfalar"
    private static let notebookKey = "son.defter"

    /// Defterde en son bakılan sayfanın sırası (yoksa 0)
    static func page(_ id: UUID) -> Int {
        (UserDefaults.standard.dictionary(forKey: pagesKey)?[id.uuidString] as? Int) ?? 0
    }

    static func setPage(_ page: Int, for id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: pagesKey) ?? [:]
        all[id.uuidString] = page
        UserDefaults.standard.set(all, forKey: pagesKey)
    }

    static var notebook: UUID? {
        get { UserDefaults.standard.string(forKey: notebookKey).flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: notebookKey) }
    }
}

/// Ana ekranda uygulama simgesine basılı tutunca çıkan kısayollar
enum QuickAction: Equatable {
    case newNote
    case open(UUID)

    private static let newNoteType = "io.github.biggypanda.openleaf.yeni-not"
    private static let openType = "io.github.biggypanda.openleaf.son-defter"

    init?(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case Self.newNoteType:
            self = .newNote
        case Self.openType:
            guard let raw = item.userInfo?["id"] as? String, let id = UUID(uuidString: raw) else { return nil }
            self = .open(id)
        default:
            return nil
        }
    }

    /// Kısayolları günceller: "Hızlı not" her zaman, "son defter" varsa adıyla
    @MainActor
    static func refresh(lastNotebook: Notebook?) {
        var items = [UIApplicationShortcutItem(
            type: newNoteType,
            localizedTitle: String(localized: "Hızlı not"),
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"))]
        if let nb = lastNotebook {
            items.insert(UIApplicationShortcutItem(
                type: openType,
                localizedTitle: nb.title,
                localizedSubtitle: String(localized: "Son açılan"),
                icon: UIApplicationShortcutIcon(systemImageName: "book.closed"),
                userInfo: ["id": nb.id.uuidString as NSString]), at: 0)
        }
        UIApplication.shared.shortcutItems = items
    }

    // MARK: Teslim

    /// Uygulama kapalıyken seçilen kısayol: kütüphane açılınca işlenir
    @MainActor static var pending: QuickAction?
    static let received = Notification.Name("openleaf.kisayol")

    @MainActor
    static func deliver(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = QuickAction(item) else { return false }
        pending = action
        NotificationCenter.default.post(name: received, object: nil)
        return true
    }
}

/// Kısayolları sahne temsilcisi alır; SwiftUI bunun için ayrı bir yol sunmuyor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let item = options.shortcutItem {
            MainActor.assumeIsolated { _ = QuickAction.deliver(item) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let handled = MainActor.assumeIsolated { QuickAction.deliver(shortcutItem) }
        completionHandler(handled)
    }
}
