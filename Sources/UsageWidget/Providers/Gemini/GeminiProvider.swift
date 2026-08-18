import Foundation

/// Gemini provider — "Actual billed spend (GCP)" mode.
///
/// Surfaces Gemini API spend from the user's Google Cloud billing export in BigQuery. This is a
/// spend Plan: the card always shows currency + spent, and a user-set Budget turns it into a
/// Progress percentage. The mode is optional and isolated behind `UsageProvider`; no API key,
/// browser cookie, AI Studio scrape, or undocumented endpoint is used.
struct GeminiProvider: UsageProvider {
    let provider = Provider.gemini
    let minimumPollInterval: TimeInterval = 300  // billing-export data moves slowly

    private let secrets: CredentialStore
    private let settings: SettingsModel
    private let fetcher = GeminiGCPFetcher()

    private static let projectAccount = "gemini.gcp.project-id"
    private static let tableAccount = "gemini.gcp.table"
    private static let serviceAccountAccount = "gemini.gcp.service-account-json"
    private static let servicesAccount = "gemini.gcp.services"

    init(secrets: CredentialStore, settings: SettingsModel) {
        self.secrets = secrets
        self.settings = settings
    }

    // MARK: - Auth methods

    var authMethods: [AuthMethod] { [gcpMethod] }

    private var gcpMethod: AuthMethod {
        AuthMethod(
            id: GeminiGCPFetcher.planID,
            provider: .gemini,
            title: "Gemini — Actual billed spend (GCP)",
            instructions: "Query your Google Cloud billing export in BigQuery for Gemini spend.",
            ownedPlanIDs: [GeminiGCPFetcher.planID],
            isSignedIn: { await self.authState() == .signedIn },
            signIn: { try await self.signIn() },
            signOut: { await self.signOut() }
        )
    }

    // MARK: - Whole-provider operations

    func authState() async -> ProviderAuthState {
        let hasProject = await secrets.secret(for: Self.projectAccount) != nil
        let hasTable = await secrets.secret(for: Self.tableAccount) != nil
        let hasSA = await secrets.secret(for: Self.serviceAccountAccount) != nil
        let hasServices = await secrets.secret(for: Self.servicesAccount) != nil
        return (hasProject && hasTable && hasSA && hasServices) ? .signedIn : .signedOut
    }

    func signIn() async throws -> SignInContinuation {
        let secrets = self.secrets
        let settings = self.settings
        let fetcher = self.fetcher

        return .needsFields(
            title: "Connect Gemini — Actual billed spend (GCP). Before connecting, enable Cloud Billing Standard usage-cost export to BigQuery (Cloud Billing → Billing export → Standard usage cost → Edit exports → BigQuery). The service account needs only roles/bigquery.jobUser and roles/bigquery.dataViewer.",
            fields: [
                SignInField(id: "project_id", label: "GCP project ID", placeholder: "my-gcp-project"),
                SignInField(id: "table", label: "BigQuery billing-export table", placeholder: "project.dataset.gcp_billing_export_v1_…"),
                SignInField(id: "service_account", label: "Service account JSON", placeholder: "Paste the JSON key", isSecure: true),
                SignInField(id: "budget", label: "Monthly budget (optional)", placeholder: "e.g. 50")
            ]
        ) { values in
            let projectID = values["project_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let table = values["table"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let saJSON = values["service_account"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !projectID.isEmpty, !table.isEmpty, !saJSON.isEmpty else {
                throw OAuthError.invalidResponse
            }
            guard GeminiGCPFetcher.isValidProjectID(projectID) else {
                throw ProviderError.decoding("Invalid GCP project ID — use lowercase letters, digits, and hyphens.")
            }
            guard GeminiGCPFetcher.isValidTableIdentifier(table) else {
                throw ProviderError.decoding("Invalid BigQuery table identifier — expected project.dataset.table with letters, digits, underscores, and hyphens only.")
            }
            // Validate the service-account JSON before persisting it.
            _ = try GoogleServiceAccountTokenFetcher.parseServiceAccount(saJSON)

            await secrets.saveSecret(projectID, for: Self.projectAccount)
            await secrets.saveSecret(table, for: Self.tableAccount)
            await secrets.saveSecret(saJSON, for: Self.serviceAccountAccount)

            if let budgetText = values["budget"]?.trimmingCharacters(in: .whitespaces),
               let amount = Self.parseBudget(budgetText), amount > 0 {
                await settings.setBudget(amount, currencyCode: "USD", for: GeminiGCPFetcher.planID)
            }

            // Discovery: identify the Gemini-related services in this billing export.
            let token = try await GoogleServiceAccountTokenFetcher.accessToken(serviceAccountJSON: saJSON)
            let discovered = try await fetcher.discoverServices(projectID: projectID, table: table, accessToken: token)
            guard !discovered.isEmpty else {
                throw ProviderError.decoding("No billing rows found for this project in the last 3 months — check the table identifier and that Cloud Billing export is enabled.")
            }

            return .needsSelection(
                title: "Select the Gemini services",
                instructions: "These are the services in your billing export for the last 3 months. Select the ones that are Gemini-related (e.g. Vertex AI Gemini SKUs, Gemini Code Assist). Only the current calendar month is tracked.",
                options: discovered.map { service in
                    SelectionOption(
                        id: service.service,
                        label: service.service,
                        detail: Formatting.currency(service.cost, code: service.currency)
                    )
                },
                submit: { selected in
                    guard !selected.isEmpty else { throw OAuthError.invalidResponse }
                    let data = try JSONEncoder().encode(selected)
                    guard let json = String(data: data, encoding: .utf8) else { throw OAuthError.invalidResponse }
                    await secrets.saveSecret(json, for: Self.servicesAccount)
                }
            )
        }
    }

    func signOut() async {
        await secrets.clearSecret(for: Self.projectAccount)
        await secrets.clearSecret(for: Self.tableAccount)
        await secrets.clearSecret(for: Self.serviceAccountAccount)
        await secrets.clearSecret(for: Self.servicesAccount)
    }

    // MARK: - Usage

    func fetchUsage() async throws -> ProviderUsage {
        guard let projectID = await secrets.secret(for: Self.projectAccount), !projectID.isEmpty,
              let table = await secrets.secret(for: Self.tableAccount), !table.isEmpty,
              let saJSON = await secrets.secret(for: Self.serviceAccountAccount), !saJSON.isEmpty,
              let servicesJSON = await secrets.secret(for: Self.servicesAccount), !servicesJSON.isEmpty
        else {
            throw ProviderError.notSignedIn
        }
        let services: [String]
        do {
            services = try JSONDecoder().decode([String].self, from: Data(servicesJSON.utf8))
        } catch {
            throw ProviderError.decoding("Stored Gemini service selection is malformed — sign in again.")
        }
        guard !services.isEmpty else { throw ProviderError.notSignedIn }

        let token = try await GoogleServiceAccountTokenFetcher.accessToken(serviceAccountJSON: saJSON)
        return try await fetcher.fetchSpend(projectID: projectID, table: table, services: services, accessToken: token)
    }

    private static func parseBudget(_ text: String) -> Decimal? {
        let posix = Locale(identifier: "en_US_POSIX")
        if let value = Decimal(string: text, locale: posix) { return value }
        return Decimal(string: text.replacingOccurrences(of: ",", with: "."), locale: posix)
    }
}