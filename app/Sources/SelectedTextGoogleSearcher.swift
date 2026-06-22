import AppKit
import ApplicationServices
import Foundation

final class SelectedTextGoogleSearcher: @unchecked Sendable {
    private let copyDelay: TimeInterval

    init(copyDelay: TimeInterval = 0.12) {
        self.copyDelay = copyDelay
    }

    func searchSelectedTextInChrome() {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        sendCommandC()
        Thread.sleep(forTimeInterval: copyDelay)

        let selectedText = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        snapshot.restore(to: pasteboard)

        guard !selectedText.isEmpty else {
            log("Google search skipped: no selected text copied")
            return
        }

        guard let url = googleSearchURL(for: selectedText) else {
            fputs("Google search failed: could not create search URL\n", stderr)
            return
        }

        openInChrome(url)
    }

    private func googleSearchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query)
        ]
        return components?.url
    }

    private func openInChrome(_ url: URL) {
        let chromeURL = URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: chromeURL.path) else {
            log("Google Chrome not found at \(chromeURL.path); opening search in default browser")
            NSWorkspace.shared.open(url)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: chromeURL, configuration: configuration) { _, error in
            if let error {
                fputs("Google search failed: \(error)\n", stderr)
            }
        }
    }

    private func sendCommandC() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCodeForC: CGKeyCode = 8

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForC, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeForC, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

private struct PasteboardSnapshot {
    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map(Item.init) ?? []
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.map { item -> NSPasteboardItem in
            let pasteboardItem = NSPasteboardItem()
            for entry in item.entries {
                pasteboardItem.setData(entry.data, forType: entry.type)
            }
            return pasteboardItem
        }
        pasteboard.writeObjects(pasteboardItems)
    }

    private struct Item {
        let entries: [Entry]

        init(_ item: NSPasteboardItem) {
            entries = item.types.compactMap { type in
                guard let data = item.data(forType: type) else {
                    return nil
                }
                return Entry(type: type, data: data)
            }
        }
    }

    private struct Entry {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }
}
