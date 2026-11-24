import Foundation
import SGLogging

public final class MyGramMessageHistoryStore {
    public struct EditEntry: Codable, Equatable {
        public let text: String
        public let timestamp: Int32

        public init(text: String, timestamp: Int32) {
            self.text = text
            self.timestamp = timestamp
        }
    }

    private struct PersistedState: Codable {
        var deletedMessages: [String]
        var editHistory: [String: [EditEntry]]
    }

    public static let shared = MyGramMessageHistoryStore()

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "org.mygram.messageHistoryStore", qos: .utility)
    private let maxTrackedDeleted = 20000
    private let maxTrackedEditedMessages = 5000
    private let maxEditsPerMessage = 50

    private var deletedMessages: Set<String> = []
    private var deletedOrder: [String] = []
    private var editHistory: [String: [EditEntry]] = [:]
    private var pendingSaveWorkItem: DispatchWorkItem?
    private let storageURL: URL?

    private init() {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("MyGram", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            self.storageURL = dir.appendingPathComponent("message_history.json")
        } else {
            self.storageURL = nil
        }
        self.loadFromDisk()
    }

    private func makeKey(peerId: Int64, namespace: Int32, id: Int32) -> String {
        return "\(peerId)_\(namespace)_\(id)"
    }

    public func markDeleted(peerId: Int64, namespace: Int32, id: Int32) {
        let key = self.makeKey(peerId: peerId, namespace: namespace, id: id)
        self.lock.lock()
        let inserted = self.deletedMessages.insert(key).inserted
        if inserted {
            self.deletedOrder.append(key)
            if self.deletedOrder.count > self.maxTrackedDeleted {
                let overflow = self.deletedOrder.count - self.maxTrackedDeleted
                let removed = self.deletedOrder.prefix(overflow)
                for oldKey in removed {
                    self.deletedMessages.remove(oldKey)
                }
                self.deletedOrder.removeFirst(overflow)
            }
        }
        self.lock.unlock()
        if inserted {
            self.scheduleSave()
        }
    }

    public func isDeleted(peerId: Int64, namespace: Int32, id: Int32) -> Bool {
        let key = self.makeKey(peerId: peerId, namespace: namespace, id: id)
        self.lock.lock()
        let result = self.deletedMessages.contains(key)
        self.lock.unlock()
        return result
    }

    public func unmarkDeleted(peerId: Int64, namespace: Int32, id: Int32) {
        let key = self.makeKey(peerId: peerId, namespace: namespace, id: id)
        self.lock.lock()
        let removed = self.deletedMessages.remove(key) != nil
        if removed {
            self.deletedOrder.removeAll(where: { $0 == key })
        }
        self.lock.unlock()
        if removed {
            self.scheduleSave()
        }
    }

    public func recordEdit(peerId: Int64, namespace: Int32, id: Int32, previousText: String, timestamp: Int32) {
        guard !previousText.isEmpty else {
            return
        }
        let key = self.makeKey(peerId: peerId, namespace: namespace, id: id)
        var didChange = false
        self.lock.lock()
        var entries = self.editHistory[key] ?? []
        if entries.last?.text != previousText {
            entries.append(EditEntry(text: previousText, timestamp: timestamp))
            if entries.count > self.maxEditsPerMessage {
                entries.removeFirst(entries.count - self.maxEditsPerMessage)
            }
            self.editHistory[key] = entries
            if self.editHistory.count > self.maxTrackedEditedMessages {
                if let oldestKey = self.editHistory.keys.first(where: { $0 != key }) {
                    self.editHistory.removeValue(forKey: oldestKey)
                }
            }
            didChange = true
        }
        self.lock.unlock()
        if didChange {
            self.scheduleSave()
        }
    }

    public func editEntries(peerId: Int64, namespace: Int32, id: Int32) -> [EditEntry] {
        let key = self.makeKey(peerId: peerId, namespace: namespace, id: id)
        self.lock.lock()
        let entries = self.editHistory[key] ?? []
        self.lock.unlock()
        return entries
    }

    public func hasEdits(peerId: Int64, namespace: Int32, id: Int32) -> Bool {
        let key = self.makeKey(peerId: peerId, namespace: namespace, id: id)
        self.lock.lock()
        let result = !(self.editHistory[key]?.isEmpty ?? true)
        self.lock.unlock()
        return result
    }

    public func clearAll() {
        self.lock.lock()
        self.deletedMessages.removeAll()
        self.deletedOrder.removeAll()
        self.editHistory.removeAll()
        self.lock.unlock()
        self.scheduleSave()
    }

    private func loadFromDisk() {
        guard let url = self.storageURL else {
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            return
        }
        do {
            let state = try JSONDecoder().decode(PersistedState.self, from: data)
            self.lock.lock()
            self.deletedOrder = state.deletedMessages
            self.deletedMessages = Set(state.deletedMessages)
            self.editHistory = state.editHistory
            self.lock.unlock()
        } catch {
            SGLogger.shared.log("MyGramHistory", "Failed to load message history: \(error)")
        }
    }

    private func scheduleSave() {
        guard let url = self.storageURL else {
            return
        }
        self.ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingSaveWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let snapshot = PersistedState(
                    deletedMessages: self.deletedOrder,
                    editHistory: self.editHistory
                )
                self.lock.unlock()
                do {
                    let data = try JSONEncoder().encode(snapshot)
                    try data.write(to: url, options: .atomic)
                } catch {
                    SGLogger.shared.log("MyGramHistory", "Failed to save message history: \(error)")
                }
            }
            self.pendingSaveWorkItem = workItem
            self.ioQueue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
        }
    }
}
