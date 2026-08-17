import SwiftUI

/// One provider's row: plan cards when data exists, otherwise a sign-in button that runs the
/// provider's auth flow. A signed-in provider with a stale/failed fetch shows the error plus a
/// "Retry" (re-fetch) action and a way to sign out, so it never silently sits empty.
struct ProviderRow: View {
    let provider: any UsageProvider
    let store: UsageStore

    @State private var continuation: SignInContinuation?
    @State private var flowError: String?

    var body: some View {
        let plans = store.plans.filter { $0.provider == provider.provider }
        let error = store.errors[provider.provider]
        let signedIn = store.authStates[provider.provider] == .signedIn

        VStack(alignment: .leading, spacing: 6) {
            if let continuation {
                SignInView(
                    continuation: continuation,
                    onFinished: {
                        self.continuation = nil
                        await store.refresh()
                    },
                    onCancel: { self.continuation = nil }
                )
            } else if !plans.isEmpty {
                ForEach(plans) { PlanCard(plan: $0, error: error) }
                if signedIn {
                    signOutButton
                } else {
                    connectButton
                }
            } else if signedIn {
                signedInNoData(error: error)
            } else {
                connectButton
                if let flowError {
                    Text(flowError).font(.caption2).foregroundStyle(.red)
                }
            }
        }
    }

    /// Signed in but no plan yet (fetch failed) — surface the error and offer retry / sign out.
    private func signedInNoData(error: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(provider.provider.displayName, systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(error ?? "No data yet.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Retry") {
                    Task { await store.refresh() }
                }
                Button("Sign out") {
                    Task { await store.signOut(provider) }
                }
                .buttonStyle(.link)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    /// A "Connect" button that begins the provider's auth flow.
    private var connectButton: some View {
        Button {
            beginSignIn()
        } label: {
            Label("Connect \(provider.provider.displayName)",
                  systemImage: "person.crop.circle.badge.plus")
        }
    }

    private var signOutButton: some View {
        HStack {
            Spacer()
            Button("Sign out") {
                Task { await store.signOut(provider) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
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
