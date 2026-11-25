import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ContextUI
import PresentationDataUtils
import ChatControllerInteraction
import ChatPresentationInterfaceState
import SGSimpleSettings

func appendMyGramContextMenuActions(
    chatPresentationInterfaceState: ChatPresentationInterfaceState,
    context: AccountContext,
    message: EngineRawMessage,
    controllerInteraction: ChatControllerInteraction,
    actions: inout [ContextMenuItem],
    sgActions: inout [ContextMenuItem]
) {
    let isRuLang = chatPresentationInterfaceState.strings.baseLanguageCode.hasPrefix("ru")

    let myGramEdits = MyGramMessageHistoryStore.shared.editEntries(
        peerId: message.id.peerId.toInt64(),
        namespace: message.id.namespace,
        id: message.id.id
    )
    if !myGramEdits.isEmpty {
        let editHistoryTitle = isRuLang ? "История правок" : "Edit History"
        actions.append(.action(ContextMenuActionItem(text: editHistoryTitle, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM HH:mm:ss"
            var lines: [String] = []
            for (index, entry) in myGramEdits.enumerated() {
                let dateStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(entry.timestamp)))
                lines.append("#\(index + 1) [\(dateStr)]\n\(entry.text)")
            }
            let historyBody = lines.joined(separator: "\n\n")
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            controllerInteraction.presentController(textAlertController(
                context: context,
                title: editHistoryTitle,
                text: historyBody,
                actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Conversation_ContextMenuCopy, action: {
                        UIPasteboard.general.string = historyBody
                    }),
                    TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                ],
                actionLayout: .horizontal
            ), nil)
        })))
    }

    if let mapMedia = message.media.first(where: { $0 is TelegramMediaMap }) as? TelegramMediaMap {
        let driveTitle = isRuLang ? "Ехать сюда на машине (Fake GPS)" : "Drive Here by Car (Fake GPS)"
        actions.append(.action(ContextMenuActionItem(text: driveTitle, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Location"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let destination = MyGramFakeGPSPoint(latitude: mapMedia.latitude, longitude: mapMedia.longitude)
            MyGramFakeGPSEngine.shared.startCarRoute(to: destination) { distanceMeters, etaSeconds in
                let km = String(format: "%.1f", distanceMeters / 1000.0)
                let mins = max(1, Int(round(etaSeconds / 60.0)))
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let body = isRuLang
                    ? "Маршрут на машине по дорогам построен (\(km) км, ~\(mins) мин).\nFake GPS включён — запустите трансляцию геопозиции в чате, и метка поедет к этой точке и остановится на месте."
                    : "Car route along streets is ready (\(km) km, ~\(mins) min).\nFake GPS is now ON — share your Live Location in the chat to drive there and stop at the destination."
                controllerInteraction.presentController(textAlertController(
                    context: context,
                    title: driveTitle,
                    text: body,
                    actions: [
                        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                    ]
                ), nil)
            }
        })))

        if SGSimpleSettings.shared.fakeGpsEnabled {
            let realGpsTitle = isRuLang ? "Выкл. Fake GPS (реальное гео)" : "Disable Fake GPS (Real GPS)"
            actions.append(.action(ContextMenuActionItem(text: realGpsTitle, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Clear"), color: theme.actionSheet.destructiveActionTextColor)
            }, action: { _, f in
                f(.default)
                SGSimpleSettings.shared.fakeGpsEnabled = false
            })))
        }
    }

    let aiSummaryTitle = isRuLang ? "Пересказать чат (ИИ)" : "Summarize Chat (AI)"
    actions.append(.action(ContextMenuActionItem(text: aiSummaryTitle, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Message"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        f(.default)
        let peerId = message.id.peerId
        let _ = (context.account.postbox.transaction { transaction -> [String] in
            var texts: [String] = []
            transaction.withAllMessages(peerId: peerId, reversed: true, { msg in
                if texts.count >= 40 {
                    return false
                }
                let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let author = msg.author?.debugDisplayTitle ?? "User"
                    texts.append("\(author): \(trimmed)")
                }
                return true
            })
            return texts.reversed()
        }
        |> deliverOnMainQueue).start(next: { recentTexts in
            MyGramGeminiClient.summarize(
                messages: recentTexts,
                apiKey: SGSimpleSettings.shared.geminiApiKey,
                isRussian: isRuLang
            ) { summary in
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                controllerInteraction.presentController(textAlertController(
                    context: context,
                    title: aiSummaryTitle,
                    text: summary,
                    actions: [
                        TextAlertAction(type: .genericAction, title: presentationData.strings.Conversation_ContextMenuCopy, action: {
                            UIPasteboard.general.string = summary
                        }),
                        TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
                    ],
                    actionLayout: .horizontal
                ), nil)
            }
        })
    })))

    let peerIdInt64 = message.id.peerId.toInt64()
    let isChatHidden = MyGramHiddenChatsStore.shared.isHidden(peerId: peerIdInt64)
    let hideChatTitle = isChatHidden
        ? (isRuLang ? "Убрать из скрытых (MyGram)" : "Unhide Chat (MyGram)")
        : (isRuLang ? "В скрытые чаты (MyGram)" : "Hide Chat (MyGram)")
    sgActions.append(.action(ContextMenuActionItem(text: hideChatTitle, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Lock"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        f(.default)
        let nowHidden = MyGramHiddenChatsStore.shared.toggleHidden(peerId: peerIdInt64)
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let notice = nowHidden
            ? (isRuLang ? "Чат добавлен в скрытые. Включите «Гостевой режим» в настройках MyGram, чтобы спрятать его из списка." : "Chat marked as hidden. Enable Guest Mode in MyGram settings to hide it from the chat list.")
            : (isRuLang ? "Чат убран из списка скрытых." : "Chat removed from hidden list.")
        controllerInteraction.presentController(textAlertController(
            context: context,
            title: "MyGram",
            text: notice,
            actions: [
                TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})
            ]
        ), nil)
    })))

    let quickReplies = MyGramQuickRepliesStore.shared.allReplies()
    if !quickReplies.isEmpty {
        let quickReplyTitle = isRuLang ? "Быстрые шаблоны" : "Quick Replies"
        sgActions.append(.action(ContextMenuActionItem(text: quickReplyTitle, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Copy"), color: theme.actionSheet.primaryTextColor)
        }, action: { _, f in
            f(.default)
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let sheet = UIAlertController(
                title: quickReplyTitle,
                message: isRuLang ? "Нажмите на шаблон, чтобы скопировать в буфер." : "Tap a template to copy it.",
                preferredStyle: .actionSheet
            )
            for item in quickReplies {
                sheet.addAction(UIAlertAction(title: item.title, style: .default, handler: { _ in
                    UIPasteboard.general.string = item.text
                }))
            }
            sheet.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel, handler: nil))
            controllerInteraction.navigationController()?.view.window?.rootViewController?.present(sheet, animated: true, completion: nil)
        })))
    }

    let exportChatTitle = isRuLang ? "Экспорт переписки (.txt)" : "Export Chat (.txt)"
    sgActions.append(.action(ContextMenuActionItem(text: exportChatTitle, icon: { theme in
        return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.actionSheet.primaryTextColor)
    }, action: { _, f in
        f(.default)
        let peerId = message.id.peerId
        let _ = (context.account.postbox.transaction { transaction -> String in
            let formatter = DateFormatter()
            formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
            var lines: [String] = []
            transaction.withAllMessages(peerId: peerId, reversed: true, { msg in
                if lines.count >= 500 {
                    return false
                }
                let dateStr = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(msg.timestamp)))
                let author = msg.author?.debugDisplayTitle ?? "Unknown"
                let isDel = MyGramMessageHistoryStore.shared.isDeleted(
                    peerId: msg.id.peerId.toInt64(),
                    namespace: msg.id.namespace,
                    id: msg.id.id
                )
                let delTag = isDel ? (isRuLang ? " [УДАЛЕНО]" : " [DELETED]") : ""
                let body = msg.text.isEmpty ? "[media]" : msg.text
                var line = "[\(dateStr)] \(author)\(delTag): \(body)"
                let edits = MyGramMessageHistoryStore.shared.editEntries(
                    peerId: msg.id.peerId.toInt64(),
                    namespace: msg.id.namespace,
                    id: msg.id.id
                )
                if !edits.isEmpty {
                    let historyStr = edits.map { $0.text }.joined(separator: " -> ")
                    line += "\n   (prev: \(historyStr))"
                }
                lines.append(line)
                return true
            })
            return lines.reversed().joined(separator: "\n")
        }
        |> deliverOnMainQueue).start(next: { exportedText in
            let fileName = "MyGram_chat_\(peerId.toInt64()).txt"
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try? exportedText.write(to: fileURL, atomically: true, encoding: .utf8)
            let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            controllerInteraction.navigationController()?.view.window?.rootViewController?.present(activityVC, animated: true, completion: nil)
        })
    })))
}
