import Foundation

public final class MyGramHiddenChatsStore {
    public static let shared = MyGramHiddenChatsStore()

    private let lock = NSLock()
    private var hiddenIds: Set<Int64> = []

    private init() {
        self.load()
    }

    private func load() {
        let raw = SGSimpleSettings.shared.hiddenChatIdsJson
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([Int64].self, from: data) else {
            return
        }
        self.lock.lock()
        self.hiddenIds = Set(decoded)
        self.lock.unlock()
    }

    private func saveLocked() {
        let array = Array(self.hiddenIds)
        if let data = try? JSONEncoder().encode(array),
           let str = String(data: data, encoding: .utf8) {
            SGSimpleSettings.shared.hiddenChatIdsJson = str
        }
    }

    public func isHidden(peerId: Int64) -> Bool {
        self.lock.lock()
        let result = self.hiddenIds.contains(peerId)
        self.lock.unlock()
        return result
    }

    @discardableResult
    public func toggleHidden(peerId: Int64) -> Bool {
        self.lock.lock()
        let nowHidden: Bool
        if self.hiddenIds.contains(peerId) {
            self.hiddenIds.remove(peerId)
            nowHidden = false
        } else {
            self.hiddenIds.insert(peerId)
            nowHidden = true
        }
        self.saveLocked()
        self.lock.unlock()
        return nowHidden
    }

    public func hiddenCount() -> Int {
        self.lock.lock()
        let count = self.hiddenIds.count
        self.lock.unlock()
        return count
    }

    public func clearAll() {
        self.lock.lock()
        self.hiddenIds.removeAll()
        self.saveLocked()
        self.lock.unlock()
    }
}
