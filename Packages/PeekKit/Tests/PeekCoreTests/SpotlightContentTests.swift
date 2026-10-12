import Testing
import Foundation
@testable import PeekCore

@Suite("SpotlightContent")
struct SpotlightContentTests {

    private func message(_ text: String,
                         role: ChatMessage.Role = .user,
                         context: String? = nil,
                         attachments: Int = 0) -> PersistedMessage {
        PersistedMessage(
            role: role,
            text: text,
            attachments: (0..<attachments).map {
                ImageAttachment(mimeType: "image/jpeg", data: Data([UInt8($0)]))
            },
            contextText: context
        )
    }

    @Test("indexes the conversation's text")
    func indexesText() throws {
        let item = try #require(SpotlightContent.item(
            title: "Force Touch",
            messages: [message("what is force touch"), message("a pressure sensor", role: .assistant)]
        ))
        #expect(item.title == "Force Touch")
        #expect(item.body.contains("what is force touch"))
        #expect(item.body.contains("a pressure sensor"))
    }

    @Test("indexes the selection a turn was about")
    func indexesContext() throws {
        // Searching for the text you asked about is as natural as searching
        // for what you typed.
        let item = try #require(SpotlightContent.item(
            title: "Definition",
            messages: [message("define this", context: "obtund")]
        ))
        #expect(item.body.contains("obtund"))
    }

    @Test("never indexes attachment bytes, only their count")
    func excludesAttachmentBytes() throws {
        // Screenshot bytes are a picture of the user's screen and have no
        // business in a system index.
        let item = try #require(SpotlightContent.item(
            title: "With a screenshot",
            messages: [message("what is this", attachments: 2)]
        ))
        #expect(item.summary.contains("2 screenshots"))
        #expect(item.body == "what is this")
    }

    @Test("summarises source app and message count")
    func buildsSummary() throws {
        let item = try #require(SpotlightContent.item(
            title: "t",
            messages: [message("a"), message("b", role: .assistant)],
            sourceAppName: "Notes"
        ))
        #expect(item.summary.contains("Notes"))
        #expect(item.summary.contains("2 messages"))
    }

    @Test("uses the singular for one message")
    func singularMessage() throws {
        let item = try #require(SpotlightContent.item(title: "t", messages: [message("a")]))
        #expect(item.summary.contains("1 message"))
        #expect(item.summary.contains("1 messages") == false)
    }

    @Test("caps the indexed body")
    func capsBody() throws {
        // A conversation grows without limit; the index should not.
        let long = String(repeating: "word ", count: 5_000)
        let item = try #require(SpotlightContent.item(title: "t", messages: [message(long)]))
        #expect(item.body.count == SpotlightContent.maxBodyCharacters)
    }

    @Test("does not index an empty conversation")
    func skipsEmpty() {
        // Otherwise a freshly created conversation becomes a dead result.
        #expect(SpotlightContent.item(title: "t", messages: []) == nil)
        #expect(SpotlightContent.item(title: "t", messages: [message("   ")]) == nil)
    }

    @Test("falls back to a placeholder title")
    func placeholderTitle() throws {
        let item = try #require(SpotlightContent.item(title: "  ", messages: [message("a")]))
        #expect(item.title == "Conversation")
    }

    @Test("omits the source app when there is not one")
    func omitsUnknownSource() throws {
        let item = try #require(SpotlightContent.item(title: "t", messages: [message("a")]))
        #expect(item.summary == "1 message")
    }
}
