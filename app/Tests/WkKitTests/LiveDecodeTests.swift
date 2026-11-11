import XCTest
@testable import WkKit

/// Decodes a captured `wk serve` response when WK_LIVE_FILE is set (debug aid, skipped otherwise).
final class LiveDecodeTests: XCTestCase {
    func testDecodeCapturedCleanup() throws {
        guard let path = ProcessInfo.processInfo.environment["WK_LIVE_FILE"] else { throw XCTSkip("no file") }
        struct Envelope: Decodable { var data: [CleanupItem]? }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            let decoded = try JSON.decoder.decode(Envelope.self, from: data)
            print("decoded", decoded.data?.count ?? -1)
        } catch {
            XCTFail("\(error)")
        }
    }
}
