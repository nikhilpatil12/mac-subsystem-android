import AppKit

public final class ClipboardBridge {
    private var lastChangeCount: Int
    private var timer: Timer?
    public var onHostClipboardChanged: ((String) -> Void)?

    public init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func startMonitoring(interval: TimeInterval = 0.5) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    private func checkClipboard() {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount != lastChangeCount {
            lastChangeCount = pasteboard.changeCount
            if let string = pasteboard.string(forType: .string) {
                onHostClipboardChanged?(string)
            }
        }
    }

    public func updateHostClipboard(with text: String) {
        DispatchQueue.main.async { [weak self] in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            self?.lastChangeCount = pasteboard.changeCount
        }
    }
}
