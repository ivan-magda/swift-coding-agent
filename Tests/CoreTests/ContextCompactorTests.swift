// swiftlint:disable file_length
import Foundation
import Testing

@testable import Core

// MARK: - microCompact

@Suite("microCompact")
struct MicroCompactTests {
  private func makeCompactor() -> ContextCompactor {
    ContextCompactor(transcriptDirectory: "/tmp/test-transcripts")
  }

  private func toolUseTurn(id: String, name: String) -> [Message] {
    [
      Message(
        role: .assistant,
        content: [
          .toolUse(id: id, name: name, input: .object([:]))
        ]
      ),
      Message(
        role: .user,
        content: [
          .toolResult(
            toolUseId: id,
            content: String(repeating: "x", count: 150),
            isError: false
          )
        ]
      )
    ]
  }

  @Test func noOpWhenThreeOrFewerToolResults() {
    let compactor = makeCompactor()
    var messages =
      toolUseTurn(id: "t1", name: "bash")
      + toolUseTurn(id: "t2", name: "bash")
      + toolUseTurn(id: "t3", name: "bash")

    let original = messages
    compactor.microCompact(messages: &messages)

    #expect(messages == original)
  }

  @Test func replacesOldResultsKeepsRecentThree() {
    let compactor = makeCompactor()
    var messages =
      toolUseTurn(id: "t1", name: "read_file")
      + toolUseTurn(id: "t2", name: "bash")
      + toolUseTurn(id: "t3", name: "write_file")
      + toolUseTurn(id: "t4", name: "edit_file")

    compactor.microCompact(messages: &messages)

    // First tool result (t1) should be replaced
    guard case .toolResult(_, let content, _) = messages[1].content[0] else {
      Issue.record("Expected toolResult")
      return
    }
    #expect(content == "[Previous: used read_file]")

    // Last 3 tool results (t2, t3, t4) should be intact
    for idx in [3, 5, 7] {
      guard case .toolResult(_, let content, _) = messages[idx].content[0] else {
        Issue.record("Expected toolResult at index \(idx)")
        continue
      }
      #expect(content.count == 150)
    }
  }

  @Test func skipsShortContent() {
    let compactor = makeCompactor()
    var messages: [Message] = [
      Message(
        role: .assistant,
        content: [
          .toolUse(id: "t1", name: "bash", input: .object([:]))
        ]
      ),
      Message(
        role: .user,
        content: [
          .toolResult(toolUseId: "t1", content: "short", isError: false)
        ]
      )
    ]
    messages +=
      toolUseTurn(id: "t2", name: "bash")
      + toolUseTurn(id: "t3", name: "bash")
      + toolUseTurn(id: "t4", name: "bash")

    compactor.microCompact(messages: &messages)

    // t1 has short content, should NOT be replaced even though it's old
    guard case .toolResult(_, let content, _) = messages[1].content[0] else {
      Issue.record("Expected toolResult")
      return
    }
    #expect(content == "short")
  }

  @Test func resolvesToolNamesFromAssistantMessages() {
    let compactor = makeCompactor()
    var messages =
      toolUseTurn(id: "t1", name: "read_file")
      + toolUseTurn(id: "t2", name: "write_file")
      + toolUseTurn(id: "t3", name: "edit_file")
      + toolUseTurn(id: "t4", name: "bash")

    compactor.microCompact(messages: &messages)

    guard case .toolResult(_, let content, _) = messages[1].content[0] else {
      Issue.record("Expected toolResult")
      return
    }
    #expect(content.contains("read_file"))
  }

  @Test func preservesTextBlocksInMixedContent() {
    let compactor = makeCompactor()
    var messages: [Message] = [
      Message(
        role: .assistant,
        content: [
          .toolUse(id: "t1", name: "bash", input: .object([:]))
        ]
      ),
      // Mixed message: text + tool result
      Message(
        role: .user,
        content: [
          .text("Some context"),
          .toolResult(
            toolUseId: "t1",
            content: String(repeating: "y", count: 200),
            isError: false
          )
        ]
      )
    ]
    messages +=
      toolUseTurn(id: "t2", name: "bash")
      + toolUseTurn(id: "t3", name: "bash")
      + toolUseTurn(id: "t4", name: "bash")

    compactor.microCompact(messages: &messages)

    // Text block should be preserved
    #expect(messages[1].content[0] == .text("Some context"))
    // Tool result should be replaced
    guard case .toolResult(_, let content, _) = messages[1].content[1] else {
      Issue.record("Expected toolResult")
      return
    }
    #expect(content == "[Previous: used bash]")
  }

  @Test func noOpOnEmptyMessages() {
    let compactor = makeCompactor()
    var messages: [Message] = []

    compactor.microCompact(messages: &messages)

    #expect(messages.isEmpty)
  }

  @Test func handlesErrorToolResults() {
    let compactor = makeCompactor()
    var messages: [Message] = [
      Message(
        role: .assistant,
        content: [
          .toolUse(id: "t1", name: "bash", input: .object([:]))
        ]
      ),
      Message(
        role: .user,
        content: [
          .toolResult(
            toolUseId: "t1",
            content: String(repeating: "e", count: 200),
            isError: true
          )
        ]
      )
    ]
    messages +=
      toolUseTurn(id: "t2", name: "bash")
      + toolUseTurn(id: "t3", name: "bash")
      + toolUseTurn(id: "t4", name: "bash")

    compactor.microCompact(messages: &messages)

    // Error tool result should still be compacted when old and long, preserving isError
    guard case .toolResult(_, let content, let isError) = messages[1].content[0] else {
      Issue.record("Expected toolResult")
      return
    }
    #expect(content == "[Previous: used bash]")
    #expect(isError == true)
  }

  @Test func handlesToolResultWithNoCorrespondingToolUse() {
    let compactor = makeCompactor()
    var messages: [Message] = [
      // No assistant message with toolUse for "orphan"
      Message(
        role: .user,
        content: [
          .toolResult(
            toolUseId: "orphan",
            content: String(repeating: "o", count: 200),
            isError: false
          )
        ]
      )
    ]
    messages +=
      toolUseTurn(id: "t2", name: "bash")
      + toolUseTurn(id: "t3", name: "bash")
      + toolUseTurn(id: "t4", name: "bash")

    compactor.microCompact(messages: &messages)

    // Should use "unknown" as tool name
    guard case .toolResult(_, let content, _) = messages[0].content[0] else {
      Issue.record("Expected toolResult")
      return
    }
    #expect(content == "[Previous: used unknown]")
  }
}

// MARK: - estimateTokens

@Suite("estimateTokens")
struct EstimateTokensTests {
  @Test func basicCalculation() throws {
    let compactor = ContextCompactor(transcriptDirectory: "/tmp/test")
    let messages = [
      Message.user("Hello world"),
      Message.assistant("Hi there")
    ]
    let tokens = compactor.estimateTokens(from: messages)
    let expectedBytes = try JSONEncoder().encode(messages).count
    #expect(tokens == expectedBytes / 4)
  }

  @Test func returnsZeroForEmptyArray() {
    let compactor = ContextCompactor(transcriptDirectory: "/tmp/test")
    let tokens = compactor.estimateTokens(from: [])
    // Empty array encodes as "[]" (2 bytes) -> 2/4 = 0
    #expect(tokens == 0)
  }
}

// MARK: - saveTranscript

@Suite("saveTranscript")
struct SaveTranscriptTests {
  @Test func createsFileWithCorrectFormat() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let compactor = ContextCompactor(transcriptDirectory: tempDir)
    let messages = [
      Message.user("Hello"),
      Message.assistant("Hi there")
    ]

    let path = try compactor.saveTranscript(messages)

    #expect(path.contains("transcript_"))
    #expect(path.hasSuffix(".jsonl"))

    let content = try String(contentsOfFile: path, encoding: .utf8)
    let lines = content.split(separator: "\n")
    #expect(lines.count == 2)

    // Each line should be decodable as a Message
    let decoder = JSONDecoder()
    for line in lines {
      let data = line.data(using: .utf8)!
      let message = try decoder.decode(Message.self, from: data)
      #expect(message.role == .user || message.role == .assistant)
    }
  }

  @Test func autoCreatesDirectory() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathComponent("nested").path
    defer {
      let parent = (tempDir as NSString).deletingLastPathComponent
      try? FileManager.default.removeItem(atPath: parent)
    }

    let compactor = ContextCompactor(transcriptDirectory: tempDir)
    let path = try compactor.saveTranscript([Message.user("test")])

    #expect(FileManager.default.fileExists(atPath: path))
  }

  @Test func returnedPathMatchesPattern() throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).path
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let compactor = ContextCompactor(transcriptDirectory: tempDir)
    let path = try compactor.saveTranscript([Message.user("test")])

    let filename = (path as NSString).lastPathComponent
    #expect(filename.hasPrefix("transcript_"))
    #expect(filename.hasSuffix(".jsonl"))
  }
}

// MARK: - autoCompact

private func makeTempCompactor() -> (ContextCompactor, String) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString).path
  return (ContextCompactor(transcriptDirectory: dir), dir)
}

@Suite("autoCompact")
struct AutoCompactTests {
  @Test func successReturnsTwoCompressedMessages() async {
    let (compactor, dir) = makeTempCompactor()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let mock = MockAPIClient()
    mock.responses = [makeResponse(content: [.text("Summary of conversation")])]
    let messages = [Message.user("Hello"), Message.assistant("Hi there")]

    let result = await compactor.autoCompact(
      messages: messages, using: mock, model: "test-model", focus: nil
    )

    #expect(result.count == 2)
    #expect(result[0].role == .user)
    #expect(result[1].role == .assistant)
    guard case .text(let text) = result[0].content[0] else {
      Issue.record("Expected text block")
      return
    }
    #expect(text.contains("Conversation compressed"))
    #expect(text.contains("Summary of conversation"))
    #expect(mock.requests.count == 1)
    #expect(mock.requests[0].tools == nil)
    #expect(mock.requests[0].maxTokens == 2000)
  }

  @Test func focusTextAppearsInPrompt() async {
    let (compactor, dir) = makeTempCompactor()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let mock = MockAPIClient()
    mock.responses = [makeResponse(content: [.text("Focused summary")])]

    _ = await compactor.autoCompact(
      messages: [Message.user("Hello")], using: mock, model: "test-model", focus: "file paths edited"
    )

    let promptContent = mock.requests[0].messages[0].content.textContent
    #expect(promptContent.contains("Focus on: file paths edited"))
  }

  @Test func emptyFocusStringDoesNotPrependFocusPrefix() async {
    let (compactor, dir) = makeTempCompactor()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let mock = MockAPIClient()
    mock.responses = [makeResponse(content: [.text("Summary")])]

    _ = await compactor.autoCompact(
      messages: [Message.user("Hello")], using: mock, model: "test-model", focus: ""
    )

    let promptContent = mock.requests[0].messages[0].content.textContent
    #expect(!promptContent.contains("Focus on:"))
  }

  @Test func saveTranscriptFailureReturnsOriginalMessages() async throws {
    // A directory nested under a regular file can't be created, even by root (as in CI containers).
    let blockingFile = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString).path
    try #require(FileManager.default.createFile(atPath: blockingFile, contents: Data()))
    defer { try? FileManager.default.removeItem(atPath: blockingFile) }

    let compactor = ContextCompactor(transcriptDirectory: "\(blockingFile)/transcripts")
    let messages = [Message.user("Hello"), Message.assistant("Hi there")]

    let result = await compactor.autoCompact(
      messages: messages, using: MockAPIClient(), model: "test-model", focus: nil
    )
    #expect(result == messages)
  }

  @Test func apiFailureReturnsOriginalMessages() async {
    let (compactor, dir) = makeTempCompactor()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let mock = MockAPIClient()
    mock.responses = [makeResponse(content: [.text("unused")])]
    mock.errorAtIndices = [0: MockAPIClient.MockError.simulatedError]
    let messages = [Message.user("Hello"), Message.assistant("Hi there")]

    let result = await compactor.autoCompact(
      messages: messages, using: mock, model: "test-model", focus: nil
    )
    #expect(result == messages)
  }
}
