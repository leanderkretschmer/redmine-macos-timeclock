import Foundation

nonisolated enum RedmineError: LocalizedError, Sendable {
    case invalidServerURL
    case invalidCredentials
    case missingLoginToken
    case unauthorized
    case forbidden
    case notFound
    case unsupported
    case server(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: "Ungültige Server-URL."
        case .invalidCredentials: "Anmeldung fehlgeschlagen – Benutzername oder Passwort falsch."
        case .missingLoginToken: "Login-Seite von Redmine konnte nicht gelesen werden."
        case .unauthorized: "Nicht autorisiert (401) – Zugangsdaten prüfen."
        case .forbidden: "Zugriff verweigert (403)."
        case .notFound: "Endpunkt nicht gefunden (404)."
        case .unsupported: "Mit dem API-Key nicht möglich – dafür Benutzer/Passwort hinterlegen."
        case .server(let message): message
        case .http(let code): "Serverfehler (HTTP \(code))."
        }
    }
}

/// How the timeclock of `redmine_human_resources` is reached.
nonisolated enum TimeclockAccess: Sendable {
    /// `/hr_timeclock/*.json` with API key (only if the controller has `accept_api_auth`).
    case apiKey
    /// `/hr_timeclock/*` with a browser-like session (username/password login). Full feature set.
    case session
    /// `/hr_timeclock/quick/start|stop?key=` – API key only, no pause and no read-only status.
    case quick
}

/// Talks to a Redmine 6 server: core REST API, the `redmine_human_resources`
/// timeclock and the stopwatch plugin.
///
/// Redmine ignores the session cookie for `.json` requests and ignores API keys for
/// controllers without `accept_api_auth`. Therefore:
/// - core REST (`*.json`) uses the API key, or HTTP Basic auth with username/password,
/// - plugin endpoints use the API key if accepted, otherwise a session login
///   (URLs without `.json`, JSON via `Accept` header, CSRF token for POSTs),
/// - as last resort the timeclock falls back to the plugin's API-key quick links.
actor RedmineClient {
    nonisolated struct Configuration: Equatable, Sendable {
        var baseURL: URL
        var apiKey: String
        var username: String
        var password: String

        var hasAPIKey: Bool { !apiKey.isEmpty }
        var hasCredentials: Bool { !username.isEmpty && !password.isEmpty }
    }

    private enum Auth {
        case apiKey, basic, session
    }

    private var configuration: Configuration?
    private var session = RedmineClient.makeSession()
    private var csrfToken: String?
    private var isLoggedIn = false
    private(set) var timeclockAccess: TimeclockAccess?
    private var stopwatchAuth: Auth?

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func makeSession() -> URLSession {
        // Ephemeral = private in-memory cookie jar for the Redmine session cookie.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }

    func configure(_ newConfiguration: Configuration) {
        guard newConfiguration != configuration else { return }
        configuration = newConfiguration
        session.invalidateAndCancel()
        session = Self.makeSession()
        csrfToken = nil
        isLoggedIn = false
        timeclockAccess = nil
        stopwatchAuth = nil
    }

    // MARK: - Core REST API

    func currentUser() async throws -> RedmineUser {
        try await getJSON(CurrentUserResponse.self, "/users/current.json", auth: restAuth()).user
    }

    func issues(watched: Bool) async throws -> [Issue] {
        let query = [
            URLQueryItem(name: watched ? "watcher_id" : "assigned_to_id", value: "me"),
            URLQueryItem(name: "status_id", value: "open"),
            URLQueryItem(name: "sort", value: "updated_on:desc"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        return try await getJSON(IssuesResponse.self, "/issues.json", query: query, auth: restAuth()).issues
    }

    func issue(id: Int) async throws -> Issue {
        try await getJSON(IssueResponse.self, "/issues/\(id).json", auth: restAuth()).issue
    }

    private func restAuth() throws -> Auth {
        guard let configuration else { throw RedmineError.invalidServerURL }
        return configuration.hasAPIKey ? .apiKey : .basic
    }

    // MARK: - Timeclock (redmine_human_resources)

    /// Current snapshot, or `nil` in quick mode where no side-effect-free read exists.
    func timeclockStatus() async throws -> HRSnapshot? {
        guard let configuration else { throw RedmineError.invalidServerURL }
        switch timeclockAccess {
        case .apiKey:
            return try await getJSON(HRSnapshot.self, "/hr_timeclock/status.json", auth: .apiKey)
        case .session:
            return try await getJSON(HRSnapshot.self, "/hr_timeclock/status", auth: .session)
        case .quick:
            return nil
        case nil:
            break
        }

        // First call: probe which access path works.
        var lastError: Error = RedmineError.unauthorized
        if configuration.hasAPIKey {
            do {
                let snapshot = try await getJSON(HRSnapshot.self, "/hr_timeclock/status.json", auth: .apiKey)
                timeclockAccess = .apiKey
                return snapshot
            } catch RedmineError.notFound {
                throw RedmineError.notFound
            } catch {
                lastError = error
            }
        }
        if configuration.hasCredentials {
            do {
                let snapshot = try await getJSON(HRSnapshot.self, "/hr_timeclock/status", auth: .session)
                timeclockAccess = .session
                return snapshot
            } catch RedmineError.notFound {
                throw RedmineError.notFound
            } catch {
                lastError = error
            }
        }
        if configuration.hasAPIKey {
            timeclockAccess = .quick
            return nil
        }
        throw lastError
    }

    func perform(_ action: ClockAction) async throws -> HRSnapshot {
        if timeclockAccess == nil { _ = try await timeclockStatus() }
        switch timeclockAccess {
        case .apiKey:
            let data = try await send("POST", "/hr_timeclock/\(action.rawValue).json", auth: .apiKey)
            return try decoder.decode(HRSnapshot.self, from: data)
        case .session:
            let data = try await send("POST", "/hr_timeclock/\(action.rawValue)", auth: .session)
            if let snapshot = try? decoder.decode(HRSnapshot.self, from: data) { return snapshot }
            // E.g. redirected to the HTML page when a correction is pending – just re-read.
            guard let snapshot = try await timeclockStatus() else { throw RedmineError.unsupported }
            return snapshot
        case .quick, nil:
            return try await performQuick(action)
        }
    }

    /// `GET /hr_timeclock/quick/<start|stop>?key=` – renders an HTML card with today's numbers.
    private func performQuick(_ action: ClockAction) async throws -> HRSnapshot {
        guard let configuration, configuration.hasAPIKey else { throw RedmineError.unsupported }
        let quickAction: String
        switch action {
        case .start: quickAction = "start"
        case .stop: quickAction = "stop"
        case .pause, .resume: throw RedmineError.unsupported
        }

        var request = URLRequest(url: try url(
            "/hr_timeclock/quick/\(quickAction)",
            query: [URLQueryItem(name: "key", value: configuration.apiKey)]
        ))
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        let cardStatus = Self.firstMatch(#"hr-quick-status-(\w+)"#, in: html) ?? "error"
        let title = Self.firstMatch(#"<h1 class="hr-quick-title">\s*(.*?)\s*</h1>"#, in: html)

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), cardStatus != "error" else {
            if code == 404 { throw RedmineError.notFound }
            throw RedmineError.server(title ?? "Stempeluhr-Fehler (HTTP \(code)).")
        }

        let state: ClockState
        if cardStatus == "warning" {
            state = .needsCorrection
        } else {
            state = action == .start ? .working : .idle
        }

        // <dl class="hr-quick-snapshot">: worked today, target today, overtime or expected end.
        let values = Self.allMatches(#"<dd>\s*(.*?)\s*</dd>"#, in: html)
        let worked = values.first.flatMap(Self.parseHoursMinutes) ?? 0
        let target = values.count > 1 ? Self.parseHoursMinutes(values[1]) ?? 0 : 0
        let expectedEnd = values.dropFirst(2).compactMap(Self.parseTimeOfDay).first

        return HRSnapshot(
            state: state.rawValue,
            workedSecondsToday: worked,
            currentBreakSeconds: 0,
            totalBreakSecondsToday: 0,
            dailyTargetSeconds: target,
            expectedEndUnix: expectedEnd.map { Int($0.timeIntervalSince1970) },
            pollIntervalSeconds: nil,
            pendingCorrection: nil
        )
    }

    // MARK: - Stopwatch plugin

    func stopwatchCurrent() async throws -> StopwatchTimer {
        guard let configuration else { throw RedmineError.invalidServerURL }
        switch stopwatchAuth {
        case .apiKey:
            return try await getJSON(StopwatchTimer.self, "/stopwatch_timers/current.json", auth: .apiKey)
        case .session:
            return try await getJSON(StopwatchTimer.self, "/stopwatch_timers/current", auth: .session)
        default:
            break
        }

        var lastError: Error = RedmineError.unsupported
        if configuration.hasAPIKey {
            do {
                let timer = try await getJSON(StopwatchTimer.self, "/stopwatch_timers/current.json", auth: .apiKey)
                stopwatchAuth = .apiKey
                return timer
            } catch {
                lastError = error
            }
        }
        if configuration.hasCredentials {
            let timer = try await getJSON(StopwatchTimer.self, "/stopwatch_timers/current", auth: .session)
            stopwatchAuth = .session
            return timer
        }
        throw lastError
    }

    // MARK: - Requests

    private func getJSON<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = [], auth: Auth) async throws -> T {
        let data = try await send("GET", path, query: query, auth: auth)
        return try decoder.decode(T.self, from: data)
    }

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], auth: Auth, allowRelogin: Bool = true) async throws -> Data {
        guard let configuration else { throw RedmineError.invalidServerURL }
        if auth == .session && !isLoggedIn {
            try await login(configuration)
        }

        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .apiKey:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "X-Redmine-API-Key")
            request.httpShouldHandleCookies = false
        case .basic:
            let credentials = Data("\(configuration.username):\(configuration.password)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
            request.httpShouldHandleCookies = false
        case .session:
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            if method != "GET", let csrfToken {
                request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
            }
        }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // An expired session yields 401/403 or a redirect to the login page.
        let bouncedToLogin = response.url?.path.hasSuffix("/login") == true
        if auth == .session && allowRelogin && (status == 401 || status == 403 || status == 422 || bouncedToLogin) {
            isLoggedIn = false
            return try await send(method, path, query: query, auth: auth, allowRelogin: false)
        }
        if bouncedToLogin { throw RedmineError.unauthorized }
        switch status {
        case 200..<300: return data
        case 401: throw RedmineError.unauthorized
        case 403: throw RedmineError.forbidden
        case 404: throw RedmineError.notFound
        default: throw RedmineError.http(status)
        }
    }

    /// Form login against `/login`, keeping the session cookie and CSRF token.
    private func login(_ configuration: Configuration) async throws {
        guard configuration.hasCredentials else { throw RedmineError.unsupported }
        let loginURL = try url("/login")
        var pageRequest = URLRequest(url: loginURL)
        pageRequest.setValue("text/html", forHTTPHeaderField: "Accept")
        let (loginPage, _) = try await session.data(for: pageRequest)
        let loginHTML = String(decoding: loginPage, as: UTF8.self)
        guard let token = Self.formToken(in: loginHTML) else {
            throw RedmineError.missingLoginToken
        }

        var request = URLRequest(url: loginURL)
        request.httpMethod = "POST"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncoded([
            ("utf8", "✓"),
            ("authenticity_token", token),
            ("back_url", ""),
            ("username", configuration.username),
            ("password", configuration.password),
            ("login", "Anmelden"),
        ])

        let (page, response) = try await session.data(for: request)
        let finalPath = response.url?.path ?? ""
        if finalPath.hasSuffix("/login") {
            throw RedmineError.invalidCredentials
        }
        if finalPath.contains("twofa") {
            throw RedmineError.server("Zwei-Faktor-Anmeldung wird nicht unterstützt – bitte API-Key verwenden.")
        }
        // Rails rotates the session on login, so take the fresh CSRF token from the landing page.
        let html = String(decoding: page, as: UTF8.self)
        csrfToken = Self.metaCSRFToken(in: html) ?? token
        isLoggedIn = true
    }

    // MARK: - Helpers

    private func url(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let configuration else { throw RedmineError.invalidServerURL }
        var base = configuration.baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard var components = URLComponents(string: base + path) else { throw RedmineError.invalidServerURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw RedmineError.invalidServerURL }
        return url
    }

    /// Finds the hidden `authenticity_token` input, regardless of attribute order.
    private static func formToken(in html: String) -> String? {
        for input in allMatches(#"(<input[^>]*name="authenticity_token"[^>]*>)"#, in: html) {
            if let value = firstMatch(#"value="([^"]+)""#, in: input) { return value }
        }
        return metaCSRFToken(in: html)
    }

    private static func metaCSRFToken(in html: String) -> String? {
        for meta in allMatches(#"(<meta[^>]*name="csrf-token"[^>]*>)"#, in: html) {
            if let value = firstMatch(#"content="([^"]+)""#, in: meta) { return value }
        }
        return nil
    }

    /// `"3h 42min"` → seconds.
    private static func parseHoursMinutes(_ text: String) -> Int? {
        let numbers = allMatches(#"(\d+)"#, in: text).compactMap { Int($0) }
        guard text.contains("h"), numbers.count >= 2 else { return nil }
        return numbers[0] * 3600 + numbers[1] * 60
    }

    /// `"17:30"` → today at that time.
    private static func parseTimeOfDay(_ text: String) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, !text.contains("h") else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { unescapeHTML(String(text[$0])) }
        }
    }

    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&#43;", with: "+")
            .replacingOccurrences(of: "&#x2F;", with: "/")
            .replacingOccurrences(of: "&#47;", with: "/")
            .replacingOccurrences(of: "&#61;", with: "=")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
