import SwiftUI

@main
struct YaprakApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .tint(Y.accent)
                .environment(\.locale, Locale(identifier: "tr_TR"))
                // Başka uygulamadan gelen PDF yeni pencere açmasın, açık pencerede içe aktarılsın
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
    }
}
