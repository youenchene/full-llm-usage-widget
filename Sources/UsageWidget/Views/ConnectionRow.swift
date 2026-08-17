import SwiftUI

/// One auth method's connection row in the dedicated Accounts panel: shows connection state and
/// hosts the sign-in flow / sign-out action for that method alone. Multi-method providers render
/// one row per method (OpenCode Go + Zen; Claude subscription + API key).
struct ConnectionRow: View {
    let method: AuthMethod
    let store: UsageStore

    @State private var continuation: SignInContinuation?
    @State private var flowError: String?
    @State private var signedIn = false

    var body: some View {
        let error = store.errors[method.provider]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.title)
                        .font(.headline)
                    Text(method.instructions)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge(signedIn: signedIn)
            }

            if let continuation {
                SignInView(
                    continuation: continuation,
                    onFinished: {
                        self.continuation = nil
                        await refreshSignedIn()
                        await store.refresh(force: true)
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
                        Task {
                            await store.signOut(method)
                            await refreshSignedIn()
                        }
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
        .task { await refreshSignedIn() }
    }

    private func refreshSignedIn() async {
        signedIn = await method.isSignedIn()
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
                let result = try await method.signIn()
                switch result {
                case .completed:
                    await refreshSignedIn()
                    await store.refresh(force: true)
                default:
                    continuation = result
                }
            } catch let err {
                flowError = err.localizedDescription
            }
        }
    }
}
