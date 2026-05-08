import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import SQLCipher
import Testing
import UniformTypeIdentifiers
@testable import DeskBrief

final class FakeKeychainStore: KeychainStoring {
    private var values: [String: String]
    var queuedReadResults: [KeychainReadResult] = []
    var queuedResults: [KeychainWriteResult] = []

    init(values: [String: String] = [:], queuedReadResults: [KeychainReadResult] = []) {
        self.values = values
        self.queuedReadResults = queuedReadResults
    }

    func readString(for account: String) -> KeychainReadResult {
        if !queuedReadResults.isEmpty {
            return queuedReadResults.removeFirst()
        }

        guard let value = values[account] else {
            return .notFound(account: account)
        }
        return .success(account: account, value: value)
    }

    @discardableResult
    func set(_ value: String, for account: String) -> KeychainWriteResult {
        if !queuedResults.isEmpty {
            let result = queuedResults.removeFirst()
            if result.isSuccess {
                apply(value, for: account)
            }
            return result
        }

        apply(value, for: account)
        return .success(account: account, operation: value.isEmpty ? .delete : .update)
    }

    private func apply(_ value: String, for account: String) {
        if value.isEmpty {
            values.removeValue(forKey: account)
        } else {
            values[account] = value
        }
    }
}

func makeTemporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("sqlite")
}

func removeTemporaryDatabaseFiles(at databaseURL: URL) {
    try? AppDatabase.removeDatabaseFiles(at: databaseURL)
}

func writeTestScreenshotPlaceholder(to url: URL) throws {
    try writeSolidTestScreenshot(to: url, gray: 3)
}

func writeSolidTestScreenshot(
    to url: URL,
    gray: UInt8,
    width: Int = 4,
    height: Int = 4
) throws {
    let pixelCount = width * height
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixelCount * 4)
    for _ in 0..<pixelCount {
        pixels.append(gray)
        pixels.append(gray)
        pixels.append(gray)
        pixels.append(UInt8.max)
    }

    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else {
        throw NSError(
            domain: "DeskBriefTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create solid test screenshot"]
        )
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(
            domain: "DeskBriefTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Failed to write solid test screenshot"]
        )
    }
}

func makeSolidTestScreenshotData(
    gray: UInt8,
    width: Int = 4,
    height: Int = 4
) throws -> Data {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jpg")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeSolidTestScreenshot(to: url, gray: gray, width: width, height: height)
    return try Data(contentsOf: url)
}

func makeSolidTestCGImage(
    gray: UInt8,
    width: Int = 4,
    height: Int = 4
) throws -> CGImage {
    let pixelCount = width * height
    var pixels: [UInt8] = []
    pixels.reserveCapacity(pixelCount * 4)
    for _ in 0..<pixelCount {
        pixels.append(gray)
        pixels.append(gray)
        pixels.append(gray)
        pixels.append(UInt8.max)
    }

    let data = Data(pixels)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ) else {
        throw NSError(
            domain: "DeskBriefTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Failed to create solid test image"]
        )
    }

    return image
}

final class LockedDoubleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    func append(_ value: Double) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class LockedBoolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setTrue() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isTrue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func makeScreenshotDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int
) -> Date {
    var components = DateComponents()
    components.calendar = Calendar.current
    components.timeZone = .current
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return components.date!
}

func waitForSemaphore(_ semaphore: DispatchSemaphore, timeoutSeconds: TimeInterval) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeoutSeconds) == .success)
        }
    }
}

@MainActor
final class SpyAppNotificationSender: AppNotificationSending {
    private(set) var messages: [AppNotificationMessage] = []

    func send(_ message: AppNotificationMessage) async {
        messages.append(message)
    }
}

@MainActor
func waitUntil(
    timeoutSeconds: TimeInterval,
    condition: @MainActor @escaping () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return condition()
}

func openSQLite(at url: URL) throws -> OpaquePointer? {
    try openSQLite(at: url, passphrase: nil)
}

func openSQLite(at url: URL, passphrase: DatabasePassphrase?) throws -> OpaquePointer? {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        sqlite3_close(handle)
        throw DatabaseError.openDatabase(message)
    }

    if let passphrase {
        let bytes = Array(passphrase.value.utf8)
        let rc = bytes.withUnsafeBufferPointer { buffer in
            sqlite3_key(handle, buffer.baseAddress, Int32(buffer.count))
        }
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite key failed"
            sqlite3_close(handle)
            throw DatabaseError.invalidPassphrase(message)
        }
    }
    return handle
}

func columnNames(in table: String, databaseURL: URL) throws -> [String] {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    var columns: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 1) {
            columns.append(String(cString: text))
        }
    }
    return columns
}

func fetchOptionalString(_ sql: String, databaseURL: URL) throws -> String? {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        return nil
    }
    guard sqlite3_column_type(statement, 0) != SQLITE_NULL,
          let text = sqlite3_column_text(statement, 0) else {
        return nil
    }
    return String(cString: text)
}

func fetchInt(_ sql: String, databaseURL: URL) throws -> Int {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw DatabaseError.execute("sqlite query returned no rows")
    }
    return Int(sqlite3_column_int64(statement, 0))
}

func indexNames(databaseURL: URL) throws -> [String] {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    var statement: OpaquePointer?
    let sql = "SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name;"
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
        throw DatabaseError.prepareStatement(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite prepare failed")
    }
    defer { sqlite3_finalize(statement) }

    var names: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        if let text = sqlite3_column_text(statement, 0) {
            names.append(String(cString: text))
        }
    }
    return names
}

func executeSQLite(_ sql: String, databaseURL: URL) throws {
    let handle = try openSQLite(at: databaseURL)
    defer { sqlite3_close(handle) }

    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw DatabaseError.execute(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite execute failed")
    }
}

func makeTestCalendar() -> Calendar {
    var calendar = Calendar.reportCalendar(language: .simplifiedChinese)
    calendar.timeZone = TimeZone(identifier: "America/Edmonton") ?? .current
    return calendar
}

func makeAnalysisRun(database: AppDatabase) throws -> Int64 {
    try database.createAnalysisRun(
        modelName: "test-model",
        totalItems: 1
    )
}

func makeModelSettings(
    provider: ModelProvider,
    apiBaseURL: String,
    modelName: String,
    apiKey: String = "",
    explicitLoadUnloadModel: Bool = AppDefaults.lmStudioExplicitLoadUnloadModel
) -> ModelProfileSettings {
    ModelProfileSettings(
        provider: provider,
        apiBaseURL: apiBaseURL,
        modelName: modelName,
        apiKey: apiKey,
        lmStudioContextLength: AppDefaults.lmStudioContextLength,
        imageAnalysisMethod: .ocr,
        explicitLoadUnloadModel: explicitLoadUnloadModel
    )
}

func makeTestSettingsSnapshot(
    screenshotIntervalMinutes: Int = 10,
    analysisStartupMode: AnalysisStartupMode = .manual,
    appLanguage: AppLanguage = .simplifiedChinese
) -> AppSettingsSnapshot {
    AppSettingsSnapshot(
        screenshotIntervalMinutes: screenshotIntervalMinutes,
        screenshotStorageLocation: .disk,
        analysisTimeMinutes: 9 * 60,
        analysisStartupMode: analysisStartupMode,
        autoAnalysisRequiresCharger: false,
        appLanguage: appLanguage,
        summaryInstruction: "测试总结说明",
        screenshotAnalysisModelProfile: makeModelSettings(
            provider: .openAI,
            apiBaseURL: "https://analysis.example.com",
            modelName: "analysis-model"
        ),
        workContentSummaryModelProfile: makeModelSettings(
            provider: .openAI,
            apiBaseURL: "https://summary.example.com",
            modelName: "summary-model"
        ),
        categoryRules: [
            CategoryRule(name: "专注工作", description: "工作"),
            CategoryRule(name: "会议沟通", description: "会议"),
            CategoryRule(name: AppDefaults.absenceCategoryName, description: "离开")
        ]
    )
}

func makeMockSession(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
) -> URLSession {
    MockURLProtocol.requestHandler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

func makeHTTPResponse(
    url: URL,
    body: String,
    statusCode: Int = 200,
    headerFields: [String: String] = ["Content-Type": "application/json"]
) throws -> (HTTPURLResponse, Data) {
    guard let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headerFields
    ) else {
        throw URLError(.badServerResponse)
    }
    return (response, Data(body.utf8))
}

func lmStudioLifecycleTestResponse(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
    let path = try #require(request.url?.path)
    let requestBody = requestBodyData(from: request)
    let body = try requestBody.flatMap {
        try JSONSerialization.jsonObject(with: $0) as? [String: Any]
    } ?? [:]

    switch path {
    case "/api/v1/models/load":
        let model = try #require(body["model"] as? String)
        #expect(body["context_length"] as? Int != nil)
        #expect(body["echo_load_config"] as? Bool == true)
        return try makeHTTPResponse(
            url: try #require(request.url),
            body: """
            {
              "type": "llm",
              "instance_id": "\(model)-instance",
              "status": "loaded"
            }
            """
        )
    case "/api/v1/models/unload":
        let instanceID = try #require(body["instance_id"] as? String)
        return try makeHTTPResponse(
            url: try #require(request.url),
            body: #"{"instance_id":"\#(instanceID)"}"#
        )
    case "/api/v1/models":
        return try makeHTTPResponse(
            url: try #require(request.url),
            body: """
            {
              "models": [
                {
                  "key": "analysis-model",
                  "loaded_instances": [
                    {
                      "identifier": "analysis-model-instance",
                      "config": {
                        "context_length": 6000
                      }
                    }
                  ]
                },
                {
                  "key": "summary-model",
                  "loaded_instances": [
                    {
                      "id": "summary-model-instance",
                      "config": {
                        "context_length": 12000
                      }
                    }
                  ]
                }
              ]
            }
            """
        )
    case "/api/v1/chat":
        if body["input"] is String {
            return try makeHTTPResponse(
                url: try #require(request.url),
                body: """
                {
                  "model_instance_id": "summary-model-instance",
                  "output": [
                    {
                      "type": "message",
                      "content": "{\\"dailySummary\\":\\"完成了前一天日报总结\\",\\"categorySummaries\\":{\\"专注工作\\":\\"总结了前一天专注工作\\"}}"
                    }
                  ]
                }
                """
            )
        }

        return try makeHTTPResponse(
            url: try #require(request.url),
            body: """
            {
              "model_instance_id": "analysis-model-instance",
              "output": [
                {
                  "type": "message",
                  "content": "{\\"category\\":\\"专注工作\\",\\"summary\\":\\"完成截屏分析\\"}"
                }
              ]
            }
            """
        )
    case "/v1/chat/completions":
        let model = try #require(body["model"] as? String)
        let responseText = model == "summary-model"
            ? #"{\"dailySummary\":\"完成了前一天日报总结\",\"categorySummaries\":{\"专注工作\":\"总结了前一天专注工作\"}}"#
            : #"{\"category\":\"专注工作\",\"summary\":\"完成截屏分析\"}"#
        return try makeHTTPResponse(
            url: try #require(request.url),
            body: """
            {
              "choices": [
                {
                  "message": {
                    "content": "\(responseText)"
                  },
                  "finish_reason": "stop"
                }
              ]
            }
            """
        )
    default:
        throw URLError(.badURL)
    }
}

func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    let bufferSize = 4096
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let readCount = stream.read(buffer, maxLength: bufferSize)
        guard readCount > 0 else {
            break
        }
        data.append(buffer, count: readCount)
    }

    return data.isEmpty ? nil : data
}

func openAIImageData(from request: URLRequest) throws -> Data {
    let requestBody = try #require(requestBodyData(from: request))
    let body = try #require(JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: Any]])
    let firstMessage = try #require(messages.first)
    let content = try #require(firstMessage["content"] as? [[String: Any]])
    let imageBlock = try #require(content.first { $0["type"] as? String == "image_url" })
    let imageURL = try #require(imageBlock["image_url"] as? [String: Any])
    let dataURL = try #require(imageURL["url"] as? String)
    let base64Prefix = "data:image/jpeg;base64,"
    #expect(dataURL.hasPrefix(base64Prefix))
    return try #require(Data(base64Encoded: String(dataURL.dropFirst(base64Prefix.count))))
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    static var requestCount = 0
    static var lastRequestedModel: String?
    static var requestPaths: [String] = []

    static func reset() {
        requestHandler = nil
        requestCount = 0
        lastRequestedModel = nil
        requestPaths = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            if let path = request.url?.path {
                Self.requestPaths.append(path)
            }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
