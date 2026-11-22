// İCloud eşitleme arayüzü: yedekleme menüsündeki bölüm (anahtar, durum, bulut verisini silme)
// ve denetleyicinin bildirimlerini gösteren görünüm değiştiricisi.

import SwiftUI

/// Yedekleme menüsüne konan bölüm. Silme onayı menünün dışında gösterilir (menü kapanınca
/// içindeki pencereler de kapanır); bu yüzden onay bayrağı dışarıdan bağlanır.
struct SyncMenuSection: View {
    @Environment(SyncController.self) private var sync
    @Binding var confirmDelete: Bool

    var body: some View {
        Toggle(isOn: Binding(get: { sync.isOn }, set: { sync.setEnabled($0) })) {
            Label("iPad'ler arasında eşitle", systemImage: "arrow.triangle.2.circlepath.icloud")
            if let line = sync.status.line {
                Text(line)
            }
        }
        // Hesap yokken eşitleme açılamaz (açıksa oturum açılınca kendiliğinden sürer)
        .disabled(sync.status == .noAccount)
        Button(role: .destructive) { confirmDelete = true } label: {
            Label("iCloud'daki eşitleme verisini sil…", systemImage: "icloud.slash")
        }
        .disabled(sync.status == .noAccount)
    }
}

extension SyncController {
    /// Anahtarın konumu. `state` gözlenmez ama her açma/kapamada `status` da değişir, görünüm yenilenir.
    var isOn: Bool {
        switch status {
        case .off, .stopped: false
        case .noAccount: state.enabled   // kapalıyken de oturum yoksa bu durum gösterilir
        default: true
        }
    }
}

extension SyncStatus {
    /// Menüdeki durum satırı; kapalıyken satır yok
    var line: String? {
        switch self {
        case .off, .stopped: nil
        case .noAccount: String(localized: "iCloud oturumu yok")
        case .syncing: String(localized: "Eşitleniyor…")
        case .upToDate: String(localized: "Eşitlendi")
        case .offline: String(localized: "Çevrimdışı, bağlanınca gönderilecek")
        case .quotaFull: String(localized: "iCloud dolu")
        }
    }
}

extension SyncNotice {
    var message: String {
        switch self {
        case .rescued(let n):
            String(localized: "\(n) sayfa başka bir iPad'de silinmişti ama burada üzerine yazılmıştı. Bu sayfalar geri getirildi ve yer imiyle işaretlendi.")
        case .stopped(.accountChanged):
            String(localized: "iCloud hesabı değiştiği için eşitleme durdu. Bu iPad'deki notlar yerinde.")
        case .stopped(.cloudDataDeleted):
            String(localized: "iCloud'daki eşitleme verisi silindiği için eşitleme durdu. Bu iPad'deki notlar yerinde.")
        }
    }
}

private struct SyncNotices: ViewModifier {
    let sync: SyncController
    @Binding var confirmDelete: Bool
    @State private var deleteError: String?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .alert(sync.notice?.message ?? "",
                   isPresented: Binding(get: { sync.notice != nil }, set: { if !$0 { sync.clearNotice() } })) {
                Button("Tamam", role: .cancel) { sync.clearNotice() }
            }
            .confirmationDialog("Eşitleme verisi iCloud'dan silinsin mi? Bu iPad'deki ve diğer iPad'lerdeki notlar silinmez; eşitleme her yerde kapanır.",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("iCloud'daki eşitleme verisini sil…", role: .destructive) {
                    Task {
                        do { try await sync.deleteCloudData() } catch { deleteError = error.localizedDescription }
                    }
                }
                Button("Vazgeç", role: .cancel) {}
            }
            .alert(deleteError ?? "", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
                Button("Tamam", role: .cancel) {}
            }
            // Kapalıyken hesap durumu da gösterilsin: oturum yoksa anahtar devre dışı kalır
            .task { await sync.refreshAccountStatus() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await sync.refreshAccountStatus() } }
            }
    }
}

extension View {
    /// Eşitleme bildirimlerini (kurtarma, durma) ve bulut verisini silme onayını gösterir
    func syncNotices(_ sync: SyncController, confirmDelete: Binding<Bool>) -> some View {
        modifier(SyncNotices(sync: sync, confirmDelete: confirmDelete))
    }
}
