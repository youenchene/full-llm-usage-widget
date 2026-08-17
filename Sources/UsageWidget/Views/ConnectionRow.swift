import SwiftUI

/// One provider's connection row in the dedicated Accounts panel: shows connection state and
/// hosts the sign-in flow / sign-out action. Usage rendering lives in the main popover.
struct ConnectionRow: View {
    let provider: any UsageProvider
    let store: UsageStore

    @State private var continuation: SignInContinuation?
    @State private var flowError: String?

    var body: some View {
        let signedIn = store.authStates[provider.provider] == .signedIn
        let error = store.errors[provider.provider]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.provider.displayName)
                    .font(.headline)
                Spacer()
                statusBadge(signedIn: signedIn)
            }

            if let continuation {
                SignInView(
                    continuation: continuation,
                    onFinished: {
                        self.continuation = nil
                        await store.refresh()
                    },
                    onCancel: { self.continuation = nil }
                )
            } else if signedIn {
                HStack {
                    if let error {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign out") {
                        Task { await store.signOut(provider) }
                    }
                }
            } else {
                HStack {
                    Button { beginSignIn() } label: {
                        Label("Connect", systemImage: "person.crop.circle.badge.plus")
                    }
                    if let flowError {
                        Text(flowError)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    private func statusBadge(signedIn: Bool) -> some View {
        let (title, icon, color): (String, String, Color) = signedIn
            ? ("Connected", "checkmark.circle.fill", .green)
            : ("Not connected", "circle", .secondary)
        return Label(title, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func beginSignIn() {
        flowError = nil
        Task {
            do {
                let result = try await provider.signIn()
                switch result {
                case .completed:
                    await store.refresh()
                default:
                    continuation = result
                }
            } catch let err {
                flowError = err.localizedDescription
            }
        }
    }
}
