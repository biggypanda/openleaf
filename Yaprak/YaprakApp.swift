import SwiftUI

@main
struct YaprakApp: App {
    @State private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .tint(Y.accent)
                .environment(\.locale, Locale(identifier: "tr_TR"))
                // Başka uygulamadan gelen PDF yeni pencere açmasın, açık pencerede içe aktarılsın
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        // Arka plana geçerken bekleyen tüm kayıtları diske yaz
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { library.flush() }
        }
    }
}
