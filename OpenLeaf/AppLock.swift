import SwiftUI
import LocalAuthentication

/// Uygulama kilidi: açıksa uygulama her açılışta ve arka plandan dönüşte Face ID, Touch ID ya da iPad parolası ister.
@MainActor
@Observable
final class AppLock {
    private static let storageKey = "kilit.acik"

    private(set) var enabled = UserDefaults.standard.bool(forKey: AppLock.storageKey)
    /// Kilit ekranı gösteriliyor mu
    private(set) var locked = UserDefaults.standard.bool(forKey: AppLock.storageKey)
    private var authenticating = false
    /// Kilit ekranında doğrulama kendiliğinden bir kez açılır; vazgeçilirse düğmeyle tekrar denenir
    private var autoPrompted = false

    /// Menüde gösterilecek ad: cihazda hangi doğrulama varsa
    static var methodName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return String(localized: "Parola")
        }
    }

    func lock() {
        guard enabled else { return }
        locked = true
        autoPrompted = false
    }

    func autoUnlock() {
        guard locked, !autoPrompted else { return }
        autoPrompted = true
        unlock()
    }

    func unlock() {
        guard locked, !authenticating else { return }
        authenticating = true
        LAContext().evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: String(localized: "Notlarını açmak için")) { ok, _ in
            Task { @MainActor in
                self.authenticating = false
                if ok { withAnimation(Y.quick) { self.locked = false } }
            }
        }
    }

    /// Kilidi açmak için önce bir kez doğrulama ister; cihazda parola yoksa hata metnini döndürür.
    func setEnabled(_ on: Bool, failed: @escaping (String) -> Void) {
        guard on else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.storageKey)
            return
        }
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            failed(String(localized: "Uygulama kilidi için iPad'de bir parola ayarlı olmalı. iPad Ayarları'ndan bir parola ekleyebilirsin."))
            return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: String(localized: "Uygulama kilidini etkinleştirmek için")) { ok, _ in
            Task { @MainActor in
                guard ok else { return }
                self.enabled = true
                UserDefaults.standard.set(true, forKey: Self.storageKey)
            }
        }
    }
}

/// Kilitliyken her şeyin üstünü kapatan ekran. Uygulama değiştiricide de notlar görünmesin diye
/// uygulama ön planda değilken de gösterilir.
struct LockCover: View {
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if lock.locked || (lock.enabled && scenePhase != .active) {
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(Y.accent)
                Text("OpenLeaf kilitli")
                    .font(.system(.title2, design: .serif, weight: .semibold))
                    .foregroundStyle(Y.ink)
                if lock.locked {
                    Button { lock.unlock() } label: {
                        Label("Kilidi aç", systemImage: "lock.open")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Y.bg)
            .ignoresSafeArea()
            .transition(.opacity)
            .task(id: scenePhase) {
                // Uygulama öne gelince doğrulamayı kendiliğinden başlat
                if scenePhase == .active { lock.autoUnlock() }
            }
        }
    }
}
