import Foundation

public final class MyGramGeminiClient {
    public static func summarize(
        messages: [String],
        apiKey: String,
        isRussian: Bool,
        completion: @escaping (String) -> Void
    ) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            let msg = isRussian
                ? "Сначала укажите бесплатный ключ Gemini API в Настройках → Swiftgram → MYGRAM: ИИ И СКРЫТЫЕ ЧАТЫ (получить можно на aistudio.google.com)."
                : "Set your free Gemini API key in Settings → Swiftgram → MYGRAM: AI & HIDDEN CHATS (get one at aistudio.google.com)."
            DispatchQueue.main.async { completion(msg) }
            return
        }
        guard !messages.isEmpty else {
            let msg = isRussian ? "В этом чате нет текстовых сообщений для пересказа." : "No text messages found in this chat."
            DispatchQueue.main.async { completion(msg) }
            return
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(trimmedKey)"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { completion("Invalid Gemini API URL") }
            return
        }

        let promptHeader = isRussian
            ? "Кратко перескажи суть последних сообщений из этого Telegram-чата на русском языке в 4-6 понятных пунктах (без воды):\n\n"
            : "Briefly summarize the following recent Telegram chat messages in 4-6 clear bullet points:\n\n"
        let combined = promptHeader + messages.joined(separator: "\n")

        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": combined]
                    ]
                ]
            ]
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            DispatchQueue.main.async { completion("Failed to encode request") }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30.0

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(isRussian ? "Ошибка сети: \(error.localizedDescription)" : "Network error: \(error.localizedDescription)")
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                DispatchQueue.main.async {
                    completion(isRussian ? "Пустой ответ от Gemini API." : "Empty response from Gemini API.")
                }
                return
            }
            if let candidates = json["candidates"] as? [[String: Any]],
               let first = candidates.first,
               let content = first["content"] as? [String: Any],
               let parts = content["parts"] as? [[String: Any]],
               let text = parts.first?["text"] as? String {
                DispatchQueue.main.async { completion(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                return
            }
            if let errObj = json["error"] as? [String: Any],
               let errMsg = errObj["message"] as? String {
                DispatchQueue.main.async { completion("Gemini API: \(errMsg)") }
                return
            }
            DispatchQueue.main.async {
                completion(isRussian ? "Не удалось разобрать ответ Gemini." : "Could not parse Gemini response.")
            }
        }.resume()
    }
}
