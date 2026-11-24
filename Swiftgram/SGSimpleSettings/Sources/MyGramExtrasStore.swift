import Foundation

public final class MyGramSmartReadStore {
    public static let shared = MyGramSmartReadStore()

    private let lock = NSLock()
    private var allowedUntil: [Int64: TimeInterval] = [:]

    private init() {}

    public func markReplied(peerId: Int64) {
        let now = Date().timeIntervalSince1970
        self.lock.lock()
        self.allowedUntil[peerId] = now + 20.0
        self.lock.unlock()
    }

    public func canSendRead(peerId: Int64) -> Bool {
        let now = Date().timeIntervalSince1970
        self.lock.lock()
        let allowed = (self.allowedUntil[peerId] ?? 0.0) > now
        self.lock.unlock()
        return allowed
    }
}

public struct MyGramQuickReply: Codable, Equatable {
    public let title: String
    public let text: String

    public init(title: String, text: String) {
        self.title = title
        self.text = text
    }
}

public final class MyGramQuickRepliesStore {
    public static let shared = MyGramQuickRepliesStore()

    private init() {}

    public func allReplies() -> [MyGramQuickReply] {
        let raw = SGSimpleSettings.shared.quickRepliesJson
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MyGramQuickReply].self, from: data) else {
            return []
        }
        return decoded
    }

    public func save(title: String, text: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, !cleanText.isEmpty else { return }
        var list = self.allReplies().filter { $0.title != cleanTitle }
        list.append(MyGramQuickReply(title: cleanTitle, text: cleanText))
        self.persist(list)
    }

    public func delete(title: String) {
        let list = self.allReplies().filter { $0.title != title }
        self.persist(list)
    }

    private func persist(_ list: [MyGramQuickReply]) {
        if let data = try? JSONEncoder().encode(list),
           let str = String(data: data, encoding: .utf8) {
            SGSimpleSettings.shared.quickRepliesJson = str
        }
    }
}
