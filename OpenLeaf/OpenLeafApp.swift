import SwiftUI

@main
struct OpenLeafApp: App {
    @State private var library: Library
    @State private var backup: AutoBackup
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _backup = State(initialValue: AutoBackup(library: library))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(backup)
                .task { backup.start() }
                // Yeni açılan pencereler (iPad'de birden fazla olabilir) de seçili temayla başlasın
                .onAppear { theme.apply() }
                .onChange(of: theme) { _, new in new.apply() }
                .tint(Y.accent)
                // Başka uygulamadan gelen PDF yeni pencere açmasın, açık pencerede içe aktarılsın
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Arka plana geçerken bekleyen tüm kayıtları diske yaz, sonra yedeğe gönder
                library.flush()
                backup.backUpIfNeeded(inBackground: true)
            case .active:
                // iCloud oturumu bu arada açılmış ya da kapanmış olabilir
                backup.refresh()
            default:
                break
            }
        }
    }
}
