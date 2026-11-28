import SwiftUI

/// "Başka uygulamadan taşı": GoodNotes ve Notability'den defterleri PDF olarak dışa aktarıp
/// OpenLeaf'e getirmenin adımları. Altta dosya seçiciyi açan düğme var.
struct MigrationGuide: View {
    var onPick: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    step(1, "Belgeler'de Seç'e dokunun ve tüm defterleri ya da klasörleri seçin.")
                    step(2, "Paylaş > Dışa aktar'a dokunun, biçim olarak PDF'i seçin.")
                    step(3, "Paylaşım menüsünden OpenLeaf'i seçin. Klasörleriniz korunur.")
                } header: {
                    Text(verbatim: "GoodNotes")
                }
                Section {
                    step(1, "Notları seçin, Paylaş'a dokunun ve PDF'i seçin.")
                    step(2, "Paylaşım menüsünden OpenLeaf'i seçin.")
                } header: {
                    Text(verbatim: "Notability")
                } footer: {
                    Text("Başka bir uygulama kullanıyorsanız defterleri PDF ya da ZIP olarak dışa aktarıp aşağıdan seçin.")
                }
                Section("Bilmeniz gerekenler") {
                    Label("Sayfalar olduğu gibi gelir; üstüne yeni mürekkeple yazabilirsiniz.", systemImage: "pencil.tip")
                    Label("Eski el yazısı ve resimler düzenlenebilir nesneye dönüşmez.", systemImage: "scribble")
                    Label("Ses kayıtları gibi özellikler PDF'e aktarılmaz.", systemImage: "waveform")
                }
            }
            .navigationTitle("Başka uygulamadan taşı")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                    onPick()
                } label: {
                    Label("Dosyaları seç", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(n)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.tint))
                .accessibilityHidden(true)
            Text(text)
        }
    }
}
