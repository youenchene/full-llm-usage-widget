import Foundation

/// Fetches Gemini spend from a Google Cloud billing export in BigQuery — the "Actual billed
/// spend (GCP)" mode.
///
/// The user enables Cloud Billing Standard usage-cost export to BigQuery and grants a read-only
/// service account access; the widget queries the export for the current calendar month and sums
/// gross cost plus credits for the services the user identified as Gemini-related. Values are
/// billing-export estimates — they can lag and be adjusted until Google finalizes charges.
struct GeminiGCPFetcher: Sendable {
    static let planID = "gemini.gcp"
    static let planName = "Gemini (GCP)"
    static let estimateNote =
        "Billing-export estimate — not real-time; Google may adjust charges until the invoice is final."

    private static let queriesURL = "https://bigquery.googleapis.com/bigquery/v2/projects/{project}/queries"

    // MARK: - Discovery

    /// One distinct `service.description` in the billing export, with the cost attributed to it.
    struct DiscoveredService: Sendable, Equatable {
        let service: String
        let cost: Decimal
        let currency: String
    }

    /// List the distinct `service.description` values in the billing export for the project over
    /// the last few months, so the user can identify which are Gemini-related. No service
    /// description is hard-coded — the user picks from their own export.
    func discoverServices(projectID: String, table: String, accessToken: String) async throws -> [DiscoveredService] {
        guard Self.isValidTableIdentifier(table) else {
            throw ProviderError.decoding("Invalid BigQuery table identifier.")
        }
        let sql = """
        SELECT
          service.description AS service,
          SUM(CAST(IFNULL(cost, 0) AS NUMERIC)) AS cost,
          ANY_VALUE(currency) AS currency
        FROM `\(table)`
        WHERE project.id = @project_id
          AND invoice.month >= @start_month
        GROUP BY service
        ORDER BY cost DESC
        """
        let parameters = [
            QueryParameter.string("project_id", projectID),
            QueryParameter.string("start_month", Self.monthString(monthsAgo: 2))
        ]
        let result = try await runQuery(sql, parameters: parameters, projectID: projectID, accessToken: accessToken)
        return try Self.parseDiscovery(result)
    }

    // MARK: - Spend

    /// Query the current calendar month's gross cost + credits for the selected services.
    func fetchSpend(projectID: String, table: String, services: [String], accessToken: String) async throws -> ProviderUsage {
        guard Self.isValidTableIdentifier(table) else {
            throw ProviderError.decoding("Invalid BigQuery table identifier.")
        }
        let sql = """
        SELECT
          SUM(CAST(IFNULL(cost, 0) AS NUMERIC)) AS gross_cost,
          SUM(CAST(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) AS c), 0) AS NUMERIC)) AS credits,
          ANY_VALUE(currency) AS currency,
          COUNT(DISTINCT currency) AS currency_count
        FROM `\(table)`
        WHERE project.id = @project_id
          AND invoice.month = @invoice_month
          AND service.description IN UNNEST(@services)
        """
        let parameters = [
            QueryParameter.string("project_id", projectID),
            QueryParameter.string("invoice_month", Self.currentMonthString()),
            QueryParameter.stringArray("services", services)
        ]
        let result = try await runQuery(sql, parameters: parameters, projectID: projectID, accessToken: accessToken)
        return try Self.parseSpend(result)
    }

    // MARK: - Parsing

    static func parseDiscovery(_ result: BigQueryResult) throws -> [DiscoveredService] {
        var services: [DiscoveredService] = []
        for row in result.rows {
            guard row.count >= 3 else { throw ProviderError.decoding("Malformed discovery row") }
            let service = row[0]
            guard !service.isEmpty else { continue }
            let cost = Self.decimal(from: row[1]) ?? 0
            let currency = row[2].isEmpty ? "USD" : row[2]
            services.append(DiscoveredService(service: service, cost: cost, currency: currency))
        }
        return services
    }

    static func parseSpend(_ result: BigQueryResult) throws -> ProviderUsage {
        guard let row = result.rows.first else {
            // No rows → no Gemini spend in the current month.
            return Self.plan(spent: 0, currency: "USD")
        }
        guard row.count >= 4,
              let gross = Self.decimal(from: row[0]),
              let credits = Self.decimal(from: row[1]),
              let currencyCount = Int(row[3]) else {
            throw ProviderError.decoding("Malformed spend row")
        }
        guard currencyCount <= 1 else {
            throw ProviderError.decoding("Billing export mixes multiple currencies — cannot aggregate")
        }
        let currency = row[2].isEmpty ? "USD" : row[2]
        return Self.plan(spent: gross + credits, currency: currency)
    }

    private static func plan(spent: Decimal, currency: String) -> ProviderUsage {
        let plan = Plan(
            id: planID,
            provider: .gemini,
            name: planName,
            kind: .spend,
            spent: spent,
            currencyCode: currency,
            note: estimateNote,
            fetchedAt: Date()
        )
        return ProviderUsage(provider: .gemini, plans: [plan], fetchedAt: Date())
    }

    private static func decimal(from cell: String) -> Decimal? {
        Decimal(string: cell, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - BigQuery transport

    /// A query result reduced to rows of string cells. NUMERIC/INTEGER/STRING are all strings in
    /// the BigQuery REST API; FLOAT64 would be a number, which we stringify defensively.
    struct BigQueryResult: Sendable {
        let rows: [[String]]
    }

    static func parseQueryResponse(_ data: Data) throws -> BigQueryResult {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("Non-JSON BigQuery response")
        }
        if let errors = json["errors"] as? [[String: Any]], !errors.isEmpty {
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            throw ProviderError.decoding("BigQuery query failed: \(message)")
        }
        if let jobComplete = json["jobComplete"] as? Bool, !jobComplete {
            throw ProviderError.decoding("BigQuery query did not complete")
        }
        guard let rows = json["rows"] as? [[String: Any]] else {
            return BigQueryResult(rows: [])
        }
        let parsed = rows.map { row -> [String] in
            guard let f = row["f"] as? [[String: Any]] else { return [] }
            return f.map { cell in
                if let v = cell["v"] as? String { return v }
                if let v = cell["v"] as? NSNumber { return v.stringValue }
                return ""
            }
        }
        return BigQueryResult(rows: parsed)
    }

    private func runQuery(
        _ sql: String,
        parameters: [QueryParameter],
        projectID: String,
        accessToken: String
    ) async throws -> BigQueryResult {
        guard Self.isValidProjectID(projectID) else {
            throw ProviderError.decoding("Invalid GCP project ID.")
        }
        let url = URL(string: Self.queriesURL.replacingOccurrences(of: "{project}", with: projectID))!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "query": sql,
            "useLegacySql": false,
            "parameterMode": "NAMED",
            "queryParameters": parameters.map { param in
                var dict = param.json
                dict["name"] = param.name
                return dict
            }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await UsageHTTP.session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.decoding("Non-HTTP response from BigQuery")
        }
        guard (200..<300).contains(http.statusCode) else {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Self.mapHTTPError(
                status: http.statusCode,
                body: Self.errorMessage(from: data),
                retryAfter: retryAfter
            )
        }
        return try Self.parseQueryResponse(data)
    }

    /// Map a BigQuery HTTP failure into the existing `ProviderError` vocabulary.
    static func mapHTTPError(status: Int, body: String, retryAfter: TimeInterval? = nil) -> ProviderError {
        switch status {
        case 401:
            return .badCredentials("Google rejected the service account credential — check the service account JSON.")
        case 403:
            return .permissionDenied(
                "BigQuery permission denied — the service account needs roles/bigquery.jobUser and roles/bigquery.dataViewer on the project."
            )
        case 404:
            return .permissionDenied("BigQuery table not found — verify the billing-export table identifier.")
        case 429:
            return .rateLimited(retryAfter: retryAfter)
        case 400:
            if body.contains("Not found: Table") {
                return .permissionDenied("BigQuery table not found — verify the billing-export table identifier.")
            }
            return .decoding("BigQuery query failed: \(body.prefix(160))")
        default:
            return .transport("BigQuery HTTP \(status): \(body.prefix(160))")
        }
    }

    static func errorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return message
    }

    // MARK: - Validation + months

    /// A fully-qualified BigQuery table identifier is `project.dataset.table`; each part allows
    /// only letters, digits, underscores, and hyphens, so a validated identifier is safe to
    /// embed in a query (backticks, quotes, and semicolons are rejected).
    static func isValidTableIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }

    /// GCP project IDs are lowercase letters, digits, and hyphens.
    static func isValidProjectID(_ projectID: String) -> Bool {
        guard !projectID.isEmpty else { return false }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        return projectID.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Current calendar month as `YYYYMM` (the billing export's `invoice.month` format).
    static func currentMonthString(_ date: Date = Date()) -> String {
        monthString(for: date)
    }

    static func monthString(monthsAgo: Int, from date: Date = Date()) -> String {
        let shifted = Calendar(identifier: .gregorian).date(byAdding: .month, value: -monthsAgo, to: date) ?? date
        return monthString(for: shifted)
    }

    static func monthString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMM"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// A named BigQuery query parameter (standard SQL, `parameterMode: NAMED`).
struct QueryParameter: Sendable {
    let name: String
    let type: String
    let value: String?
    let arrayValues: [String]?

    static func string(_ name: String, _ value: String) -> QueryParameter {
        QueryParameter(name: name, type: "STRING", value: value, arrayValues: nil)
    }

    static func stringArray(_ name: String, _ values: [String]) -> QueryParameter {
        QueryParameter(name: name, type: "ARRAY", value: nil, arrayValues: values)
    }

    /// The `parameterType`/`parameterValue` JSON for the BigQuery request body.
    var json: [String: Any] {
        if let value {
            return [
                "parameterType": ["type": type],
                "parameterValue": ["value": value]
            ]
        }
        return [
            "parameterType": ["type": "ARRAY", "arrayType": ["type": "STRING"]],
            "parameterValue": ["arrayValues": arrayValues?.map { ["value": $0] } ?? []]
        ]
    }
}