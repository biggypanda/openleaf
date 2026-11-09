import SwiftUI

@main
struct OpenLeafApp: App {
    @State private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .tint(Y.accent)
                // Başka uygulamadan gelen PDF yeni pencere açmasın, açık pencerede içe aktarılsın
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // Arka plana geçerken bekleyen tüm kayıtları diske yaz
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { library.flush() }
        }
    }
}
