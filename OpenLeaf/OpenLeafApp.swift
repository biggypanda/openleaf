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
                .modifier(WriteFailureAlert())
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
