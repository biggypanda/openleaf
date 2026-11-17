import SwiftUI
import UniformTypeIdentifiers

/// Otomatik yedek ayarları: aç/kapa, yedek yeri, durum, bulunan yedekler ve geri yükleme.
struct AutoBackupSheet: View {
    /// Pencere açılır açılmaz geri yüklenecek yedek (kütüphane ekranındaki tekliften gelindiyse)
    var restoreOnAppear: AutoBackup.Found?

    @Environment(AutoBackup.self) private var backup
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    @State private var message: (title: String, text: String)?
    @State private var toDelete: AutoBackup.Found?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { backup.enabled }, set: { backup.setEnabled($0) })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Otomatik yedekle").font(.body.weight(.semibold))
                            statusLine
                        }
                    }
                    .tint(Y.accent)
                    if backup.enabled {
                        Button("Şimdi yedekle") { backup.backUpNow() }
                            .disabled(backup.status == .running || !backup.isAvailable)
                    }
                } footer: {
                    Text("Defterlerin sen bir şey yapmadan yedeklenir: uygulamayı açınca, kapatınca ve yazmaya ara verince. iPad'in bozulsa ya da uygulama silinse bile notların geri gelir.")
                }

                Section {
                    placeRow(title: String(localized: "iCloud"),
                             detail: backup.iCloudAvailable ? String(localized: "Kendi iCloud hesabın")
                                                            : String(localized: "Bu iPad'de iCloud oturumu açık değil"),
                             icon: "icloud", selected: backup.destination == .icloud) {
                        backup.useICloud()
                    }
                    .disabled(!backup.iCloudAvailable && backup.destination != .icloud)

                    HStack(spacing: 12) {
                        placeRow(title: String(localized: "Klasör"),
                                 detail: backup.folderName ?? String(localized: "Google Drive, Dropbox, OneDrive, USB bellek…"),
                                 icon: "folder", selected: backup.destination == .folder) {
                            if backup.folderName == nil { showFolderPicker = true } else { backup.useSavedFolder() }
                        }
                        Button(backup.folderName == nil ? String(localized: "Seç…") : String(localized: "Değiştir")) {
                            showFolderPicker = true
                        }
                        .buttonStyle(.bordered)
                        .font(.subheadline)
                    }
                } header: {
                    Text("Yedek yeri")
                } footer: {
                    Text(backup.destination == .icloud
                         ? String(localized: "Notların yalnızca senin iCloud hesabına gider. Biz göremeyiz; OpenLeaf hiçbir veri toplamaz.")
                         : String(localized: "Notların yalnızca seçtiğin klasöre yazılır. Biz göremeyiz; OpenLeaf hiçbir veri toplamaz. Klasörü Dosyalar penceresinden seçersin; Google Drive, Dropbox ya da OneDrive uygulaması kuruluysa orada görünür."))
                }

                Section {
                    if let progress = backup.restoreProgress {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Geri yükleniyor…").font(.subheadline)
                            ProgressView(value: progress).tint(Y.accent)
                        }
                        .padding(.vertical, 4)
                    }
                    if backup.found.isEmpty {
                        Text(backup.searched ? String(localized: "Bu yerde yedek yok.") : String(localized: "Yedekler aranıyor…"))
                            .font(.subheadline).foregroundStyle(Y.ink3)
                    }
                    ForEach(backup.found) { item in
                        foundRow(item)
                    }
                } header: {
                    Text("Bulunan yedekler")
                } footer: {
                    Text("Geri yükleme yalnızca bu iPad'de olmayan defterleri ekler. Var olan defterlerine dokunmaz, hiçbir şeyi silmez.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Y.surface2)
            .navigationTitle("Otomatik yedek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") { dismiss() }.disabled(backup.restoreProgress != nil)
                }
            }
        }
        .interactiveDismissDisabled(backup.restoreProgress != nil)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else { return }
            if !backup.useFolder(url) {
                message = (String(localized: "Bu klasör kullanılamıyor"),
                           String(localized: "Bu klasöre kalıcı erişim alınamadı. Başka bir klasör seçmeyi dene."))
            }
        }
        .alert(message?.title ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(message?.text ?? "")
        }
        .confirmationDialog("Bu yedek silinsin mi?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible, presenting: toDelete) { item in
            Button("Yedeği sil", role: .destructive) { Task { await backup.delete(item) } }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("Bu yedek kalıcı olarak silinir. Bu iPad'deki defterlerine bir şey olmaz.")
        }
        .task {
            backup.refresh()
            if let item = restoreOnAppear { restore(item) }
        }
    }

    // MARK: Parçalar

    @ViewBuilder
    private var statusLine: some View {
        switch backup.status {
        case .off:
            Text("Yedekleme kapalı").font(.footnote).foregroundStyle(Y.ink3)
        case .unavailable:
            Label(backup.destination == .icloud ? String(localized: "iCloud'a ulaşılamıyor")
                                                : String(localized: "Klasöre ulaşılamıyor"),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Y.danger)
        case .running:
            Text("Yedekleniyor…").font(.footnote).foregroundStyle(Y.ink3)
        case .failed(let reason):
            Label(String(localized: "Yedeklenemedi: \(reason)"), systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(Y.danger)
        case .idle:
            if backup.uploading {
                Text("iCloud'a yükleniyor…").font(.footnote).foregroundStyle(Y.ink3)
            } else if let date = backup.lastBackup {
                Text("Son yedek: \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(Y.ink3)
            } else {
                Text("Henüz yedeklenmedi").font(.footnote).foregroundStyle(Y.ink3)
            }
        }
    }

    private func placeRow(title: String, detail: String, icon: String, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Y.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Y.ink)
                    Text(detail).font(.footnote).foregroundStyle(Y.ink3).lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? Y.accent : Y.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func foundRow(_ item: AutoBackup.Found) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "ipad").font(.system(size: 17)).foregroundStyle(Y.ink3).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.isThisDevice ? String(localized: "\(item.info.name) (bu iPad)") : item.info.name)
                    .foregroundStyle(Y.ink)
                Text(verbatim: item.summary).font(.footnote).foregroundStyle(Y.ink3)
            }
            Spacer(minLength: 8)
            if !item.isThisDevice {
                Button(role: .destructive) { toDelete = item } label: {
                    Image(systemName: "trash").frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Yedeği sil")
            }
            Button("Geri yükle") { restore(item) }
                .buttonStyle(.bordered)
                .font(.subheadline)
        }
        .disabled(backup.restoreProgress != nil)
    }

    private func restore(_ item: AutoBackup.Found) {
        Task {
            do {
                let r = try await backup.restore(item)
                var text = r.added == 0 ? String(localized: "Yedekteki defterlerin hepsi zaten bu iPad'de var.")
                                        : String(localized: "\(r.added) defter geri yüklendi.")
                if r.added > 0, r.skipped > 0 { text += " " + String(localized: "\(r.skipped) defter zaten vardı, dokunulmadı.") }
                if r.failed > 0 { text += " " + String(localized: "\(r.failed) defter indirilemedi; internet bağlantını kontrol edip yeniden dene.") }
                message = (String(localized: "Geri yükleme tamam"), text)
            } catch {
                message = (String(localized: "Geri yüklenemedi"), error.localizedDescription)
            }
        }
    }
}
