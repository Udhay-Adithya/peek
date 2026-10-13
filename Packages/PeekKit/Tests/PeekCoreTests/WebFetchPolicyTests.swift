import Testing
import Foundation
import PeekCore

@Suite("WebFetchPolicy")
struct WebFetchPolicyTests {

    @Test("accepts an ordinary https page")
    func acceptsHTTPS() throws {
        let url = try WebFetchPolicy.validate("https://example.com/a/b?c=d").get()
        #expect(url.absoluteString == "https://example.com/a/b?c=d")
    }

    @Test("trims surrounding whitespace a model may include")
    func trimsWhitespace() throws {
        let url = try WebFetchPolicy.validate("  https://example.com  ").get()
        #expect(url.host == "example.com")
    }

    @Test(arguments: ["http://example.com", "file:///etc/passwd", "peek://show",
                      "ftp://example.com", "javascript:alert(1)"])
    func rejectsNonHTTPS(_ raw: String) {
        // A model-chosen URL must not downgrade to cleartext or leave the web.
        #expect(WebFetchPolicy.validate(raw).isFailure)
    }

    @Test(arguments: ["https://localhost/x", "https://localhost:8080",
                      "https://127.0.0.1", "https://127.1.2.3",
                      "https://0.0.0.0", "https://10.0.0.5",
                      "https://192.168.1.1", "https://172.16.0.1",
                      "https://172.31.255.255", "https://169.254.169.254",
                      "https://100.64.0.1", "https://[::1]",
                      "https://[fd00::1]", "https://[fe80::1]",
                      "https://router.local", "https://db.internal",
                      "https://myserver", "https://app.localhost",
                      "https://thing.test"])
    func rejectsPrivateHosts(_ raw: String) {
        // This Mac can reach routers, dev servers, databases and cloud
        // metadata that the internet cannot. A fetch tool must not become a
        // way to read them.
        #expect(WebFetchPolicy.validate(raw).isFailure, "should refuse \(raw)")
    }

    @Test("169.254.169.254 is refused by name, since it is the metadata address")
    func rejectsMetadataAddress() {
        let result = WebFetchPolicy.validate("https://169.254.169.254/latest/meta-data/")
        #expect(result.refusal == .privateHost("169.254.169.254"))
    }

    @Test("refuses a URL carrying credentials")
    func rejectsCredentials() {
        #expect(WebFetchPolicy.validate("https://user:secret@example.com").refusal
                == .embeddedCredentials)
        #expect(WebFetchPolicy.validate("https://user@example.com").refusal
                == .embeddedCredentials)
    }

    @Test(arguments: ["", "not a url", "https://", "://example.com"])
    func rejectsNonsense(_ raw: String) {
        #expect(WebFetchPolicy.validate(raw).isFailure)
    }

    @Test("a public address that merely looks private is allowed")
    func allowsLookalikes() {
        // 172.32 is outside 172.16/12, and 11.x is not private at all.
        #expect(WebFetchPolicy.validate("https://172.32.0.1").isSuccess)
        #expect(WebFetchPolicy.validate("https://11.0.0.1").isSuccess)
        #expect(WebFetchPolicy.validate("https://192.169.0.1").isSuccess)
    }

    @Test("a refusal explains itself in terms the model can repeat")
    func refusalMessages() {
        #expect(WebFetchPolicy.Refusal.notHTTPS("http").message.contains("https"))
        #expect(WebFetchPolicy.Refusal.privateHost("localhost").message.contains("localhost"))
    }
}

private extension Result where Success == URL, Failure == WebFetchPolicy.Refusal {
    var isFailure: Bool { if case .failure = self { return true }; return false }
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var refusal: WebFetchPolicy.Refusal? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
