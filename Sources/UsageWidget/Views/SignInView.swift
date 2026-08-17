import SwiftUI

/// Renders the UI for a sign-in continuation: a method chooser (multi-method providers),
/// a paste-code box (Claude), an API-key box (Mistral / Claude billing), or a device-flow code
/// display (Copilot). Codex's `.completed` never reaches here.
struct SignInView: View {
    let onFinished: () async -> Void
    let onCancel: () -> Void

    @State private var continuation: SignInContinuation
    @State private var input = ""
    @State private var fieldValues: [String: String] = [:]
    @State private var error: String?
    @State private var isWorking = false

    init(
        continuation: SignInContinuation,
        onFinished: @escaping () async -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onFinished = onFinished
        self.onCancel = onCancel
        _continuation = State(initialValue: continuation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch continuation {
            case .completed:
                EmptyView()
            case .choose(let options):
                chooseFlow(options: options)
            case .needsCode(let instructions, let submit):
                textFlow(instructions: instructions, placeholder: "Paste code", action: submit)
            case .needsKey(let instructions, let submit):
                textFlow(instructions: instructions, placeholder: "Paste API key", action: submit)
            case .needsFields(let title, let fields, let submit):
                fieldsFlow(title: title, fields: fields, action: submit)
            case .deviceCode(let userCode, let verificationURL, let instructions, let poll):
                deviceFlow(userCode: userCode, verificationURL: verificationURL, instructions: instructions, poll: poll)
            case .needsPermission(let title, let instructions, let openSettings, let retry):
                permissionFlow(title: title, instructions: instructions, openSettings: openSettings, retry: retry)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: onCancel)
                    .disabled(isWorking)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
    }

    // MARK: - Method chooser (multi-method providers)

    private func chooseFlow(options: [SignInOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose a connection method")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(options, id: \.id) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Button(option.title) { begin(option) }
                    Text(option.instructions)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func begin(_ option: SignInOption) {
        error = nil
        Task {
            do {
                continuation = try await option.start()
            } catch let err {
                self.error = err.localizedDescription
            }
        }
    }

    // MARK: - Paste-code / API-key flow

    private func textFlow(
        instructions: String,
        placeholder: String,
        action: @escaping @Sendable (String) async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(instructions).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $input)
                .textFieldStyle(.roundedBorder)
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            Button {
                submit { try await action(input) }
            } label: {
                Text(isWorking ? "Submitting…" : "Submit")
            }
            .disabled(input.isEmpty || isWorking)
        }
    }

    // MARK: - Multi-field credential flow (Scaleway)

    private func fieldsFlow(
        title: String,
        fields: [SignInField],
        action: @escaping @Sendable ([String: String]) async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label).font(.caption2).foregroundStyle(.secondary)
                    if field.isSecure {
                        SecureField(field.placeholder, text: binding(for: field.id))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        TextField(field.placeholder, text: binding(for: field.id))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            Button {
                submit { try await action(fieldValues) }
            } label: {
                Text(isWorking ? "Submitting…" : "Submit")
            }
            .disabled(isWorking)
        }
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { fieldValues[id] ?? "" },
            set: { fieldValues[id] = $0 }
        )
    }

    // MARK: - Device flow (Copilot)

    private func deviceFlow(
        userCode: String,
        verificationURL: URL,
        instructions: String,
        poll: @escaping @Sendable () async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(instructions).font(.caption).foregroundStyle(.secondary)
            Text(userCode)
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .kerning(2)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
            Button("Open \(verificationURL.host ?? "github.com")") {
                Browser.open(verificationURL)
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            Button {
                submit { try await poll() }
            } label: {
                Text(isWorking ? "Waiting for authorization…" : "I've entered the code")
            }
            .disabled(isWorking)
        }
    }

    // MARK: - System-permission flow (Cursor: Full Disk Access)

    private func permissionFlow(
        title: String,
        instructions: String,
        openSettings: (@Sendable () -> Void)?,
        retry: @escaping @Sendable () async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.bold())
            Text(instructions).font(.caption).foregroundStyle(.secondary)
            if let openSettings {
                Button("Open System Settings") { openSettings() }
            }
            if let error {
                Text(error).font(.caption2).foregroundStyle(.red)
            }
            Button {
                submit { try await retry() }
            } label: {
                Text(isWorking ? "Checking…" : "Check access")
            }
            .disabled(isWorking)
        }
    }

    // MARK: - Shared

    private func submit(_ work: @escaping () async throws -> Void) {
        isWorking = true
        error = nil
        Task {
            do {
                try await work()
                await onFinished()
            } catch let err {
                self.error = err.localizedDescription
                isWorking = false
            }
        }
    }
}
