import SwiftUI

@main
struct OpenLeafApp: App {
    @State private var library: Library
    @State private var backup: AutoBackup
    @State private var sync: SyncController
    @State private var appLock = AppLock()
    /// Ana ekran kısayolları sahne temsilcisinden gelir
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppTheme.storageKey) private var theme: AppTheme = .system

    init() {
        let library = Library()
        _library = State(initialValue: library)
        _backup = State(initialValue: AutoBackup(library: library))
        // İCloud eşitleme Library'den sonra kurulur; kapalıyken Library'ye hiçbir şey bağlamaz
        _sync = State(initialValue: SyncController(library: library,
                                                   state: SyncStateStore(root: SyncStateStore.varsayilanKok)))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .environment(backup)
                .environment(sync)
                .environment(appLock)
                .overlay { LockCover().environment(appLock) }
                .task { backup.start() }
                // Açık bırakıldıysa eşitleme başlar (yeniden çağrı zararsız: motor varsa bir şey yapmaz)
                .task { sync.startIfEnabled() }
                // Yeni açılan pencereler (iPad'de birden fazla olabilir) de seçili temayla başlasın
                .onAppear { theme.apply() }
                .onChange(of: theme) { _, new in new.apply() }
                .tint(Y.accent)
                // Başka uygulamadan gelen PDF yeni pencere açmasın, açık pencerede içe aktarılsın
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .modifier(WriteFailureAlert())
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Arka plana geçerken bekleyen tüm kayıtları diske yaz, sonra yedeğe gönder
                library.flush()
                backup.backUpIfNeeded(inBackground: true)
                appLock.lock()
                QuickAction.refresh(lastNotebook: LastOpened.notebook.flatMap { id in
                    library.notebooks.first { $0.id == id && !$0.trashed }
                })
            case .active:
                // iCloud oturumu bu arada açılmış ya da kapanmış olabilir
                backup.refresh()
            default:
                break
            }
        }
    }
}

/// Bir kayıt diske yazılamazsa (ör. depolama dolu) kullanıcıyı uyarır; her açılışta bir kez.
private struct WriteFailureAlert: ViewModifier {
    @State private var shown = false
    @State private var warned = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NotebookStore.writeFailed)
                .receive(on: DispatchQueue.main)) { _ in
                guard !warned else { return }
                warned = true
                shown = true
            }
            .alert("Kaydedilemedi", isPresented: $shown) {
                Button("Tamam", role: .cancel) {}
            } message: {
                Text("Son değişiklikler kaydedilemedi. iPad'in depolama alanı dolmuş olabilir; biraz yer açıp tekrar dene.")
            }
    }
}
