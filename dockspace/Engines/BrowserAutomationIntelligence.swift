import Foundation
import AppKit

final class BrowserAutomationIntelligence {
    struct CapturedBrowserEvent: Codable {
        let type: String       // "click", "input", "submit"
        let selector: String
        let text: String?      // button/link text
        let value: String?     // input value
        let url: String
        let timestamp: Double
    }

    var onEventCaptured: ((AutomationStep) -> Void)?

    private var timer: Timer?
    private let browserNames = ["Google Chrome", "Safari", "Arc"]

    // Injected JavaScript that sets up hooks and records interactions in window.__dockspaceEvents
    private let injectionScript = """
    (function() {
        if (window.__dockspaceInitialized) return;
        window.__dockspaceInitialized = true;
        window.__dockspaceEvents = [];

        function getCssSelector(el) {
            if (!el || el.nodeType !== Node.ELEMENT_NODE) return "";
            
            // 1. If it has an ID, use it
            if (el.id) {
                return "#" + CSS.escape(el.id);
            }
            
            // 2. For input/textarea/select, try name, type, or placeholder attributes
            if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") {
                if (el.name) {
                    return el.tagName.toLowerCase() + "[name=\\"" + el.name + "\\"]";
                }
                if (el.type && el.type !== "text" && el.type !== "password") {
                    return el.tagName.toLowerCase() + "[type=\\"" + el.type + "\\"]";
                }
                if (el.placeholder) {
                    return el.tagName.toLowerCase() + "[placeholder=\\"" + el.placeholder + "\\"]";
                }
            }
            
            // 3. For buttons and anchors, try aria-label or title
            if (el.tagName === "BUTTON" || el.tagName === "A" || el.getAttribute("role") === "button") {
                var label = el.getAttribute("aria-label") || el.getAttribute("title");
                if (label) {
                    return el.tagName.toLowerCase() + "[aria-label=\\"" + label + "\\"]";
                }
            }
            
            // 4. Generate tag + a sanitized/escaped single unique class name instead of all utility classes
            var tagName = el.tagName.toLowerCase();
            if (el.className && typeof el.className === "string") {
                var classes = el.className.split(/\\s+/).filter(function(c) {
                    // Ignore tailwind / utility classes that are very long or contain brackets/colons
                    return c && !c.includes("hover") && !c.includes("active") && !c.includes("focus") && !c.includes("[") && !c.includes(":");
                });
                if (classes.length > 0) {
                    var cleanClasses = classes.slice(0, 2).map(function(c) {
                        return "." + CSS.escape(c);
                    }).join("");
                    
                    var matches = document.querySelectorAll(tagName + cleanClasses);
                    if (matches.length === 1) {
                        return tagName + cleanClasses;
                    }
                }
            }
            
            // 5. Fallback: standard structural path selector
            var path = [];
            while (el && el.nodeType === Node.ELEMENT_NODE) {
                var selector = el.nodeName.toLowerCase();
                if (el.id) {
                    selector += "#" + CSS.escape(el.id);
                    path.unshift(selector);
                    break;
                } else {
                    var sib = el, sibCount = 0, sibIndex = 0;
                    while (sib = sib.previousSibling) {
                        if (sib.nodeType === Node.ELEMENT_NODE && sib.nodeName === el.nodeName) {
                            sibCount++;
                        }
                    }
                    sib = el;
                    while (sib = sib.nextSibling) {
                        if (sib.nodeType === Node.ELEMENT_NODE && sib.nodeName === el.nodeName) {
                            sibIndex++;
                        }
                    }
                    if (sibCount > 0 || sibIndex > 0) {
                        selector += ":nth-of-type(" + (sibCount + 1) + ")";
                    }
                    path.unshift(selector);
                }
                el = el.parentNode;
            }
            return path.join(" > ");
        }

        document.addEventListener("click", function(e) {
            var el = e.target;
            while (el && el !== document.body) {
                if (el.tagName === "BUTTON" || el.tagName === "A" || el.onclick || el.getAttribute("role") === "button") {
                    break;
                }
                el = el.parentElement;
            }
            if (!el || el === document.body) el = e.target;

            var selector = getCssSelector(el);
            var text = el.innerText || el.value || "";
            if (text.length > 60) text = text.substring(0, 60) + "...";

            window.__dockspaceEvents.push({
                type: "click",
                selector: selector,
                text: text,
                value: null,
                url: window.location.href,
                timestamp: Date.now()
            });
        }, true);

        document.addEventListener("change", function(e) {
            var el = e.target;
            if (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.tagName === "SELECT") {
                var selector = getCssSelector(el);
                var val = el.value;
                if (el.type === "password") val = "••••••••";
                window.__dockspaceEvents.push({
                    type: "input",
                    selector: selector,
                    text: null,
                    value: val,
                    url: window.location.href,
                    timestamp: Date.now()
                });
            }
        }, true);

        document.addEventListener("submit", function(e) {
            var el = e.target;
            var selector = getCssSelector(el);
            window.__dockspaceEvents.push({
                type: "submit",
                selector: selector,
                text: null,
                value: null,
                url: window.location.href,
                timestamp: Date.now()
            });
        }, true);
    })();
    """

    func start() {
        lastActiveURLs = [:]
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollBrowsers()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var lastActiveURLs: [String: String] = [:]

    private func pollBrowsers() {
        for browser in browserNames {
            guard isAppRunning(browser) else { continue }
            
            injectScript(in: browser)

            if let jsonEvents = retrieveEvents(from: browser), !jsonEvents.isEmpty && jsonEvents != "[]" {
                parseAndReportEvents(jsonEvents, browser: browser)
            }
        }
    }

    private func isAppRunning(_ name: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func injectScript(in browser: String) {
        let escapedScript = injectionScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let appleScript: String
        if browser == "Safari" {
            appleScript = """
            tell application "Safari"
                if (count of windows) > 0 then
                    tell current tab of front window
                        do JavaScript "\(escapedScript)"
                    end tell
                end if
            end tell
            """
        } else {
            appleScript = """
            tell application "\(browser)"
                if (count of windows) > 0 then
                    tell active tab of front window
                        execute javascript "\(escapedScript)"
                    end tell
                end if
            end tell
            """
        }

        _ = try? runAppleScript(appleScript)
    }

    private func retrieveEvents(from browser: String) -> String? {
        let js = """
        (function() {
            if (window.__dockspaceEvents) {
                var events = JSON.stringify(window.__dockspaceEvents);
                window.__dockspaceEvents = [];
                return events;
            }
            return "[]";
        })()
        """
        
        let escapedJs = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let appleScript: String
        if browser == "Safari" {
            appleScript = """
            tell application "Safari"
                if (count of windows) > 0 then
                    tell current tab of front window
                        return do JavaScript "\(escapedJs)"
                    end tell
                end if
            end tell
            return ""
            """
        } else {
            appleScript = """
            tell application "\(browser)"
                if (count of windows) > 0 then
                    tell active tab of front window
                        return execute javascript "\(escapedJs)"
                    end tell
                end if
            end tell
            return ""
            """
        }

        return try? runAppleScript(appleScript)
    }

    private func parseAndReportEvents(_ json: String, browser: String) {
        guard let data = json.data(using: .utf8) else { return }
        let decoder = JSONDecoder()
        guard let events = try? decoder.decode([CapturedBrowserEvent].self, from: data) else { return }

        for event in events {
            let step: AutomationStep
            let titleText = event.text ?? event.selector
            
            switch event.type {
            case "click":
                step = AutomationStep(
                    type: .clickBrowserElement,
                    title: "Click '\(titleText)' in \(browser)",
                    configuration: BrowserElementConfiguration(
                        selector: event.selector,
                        value: nil,
                        textContent: event.text,
                        xpath: nil,
                        browserName: browser,
                        actionType: "click"
                    ),
                    waitCondition: .browserElementAppears(event.selector, timeout: 10)
                )
            case "input":
                step = AutomationStep(
                    type: .inputBrowserText,
                    title: "Type '\(event.value ?? "")' in '\(event.selector)'",
                    configuration: BrowserElementConfiguration(
                        selector: event.selector,
                        value: event.value,
                        textContent: nil,
                        xpath: nil,
                        browserName: browser,
                        actionType: "input"
                    ),
                    waitCondition: .browserElementAppears(event.selector, timeout: 10)
                )
            case "submit":
                step = AutomationStep(
                    type: .submitBrowserForm,
                    title: "Submit form '\(event.selector)' in \(browser)",
                    configuration: BrowserElementConfiguration(
                        selector: event.selector,
                        value: nil,
                        textContent: nil,
                        xpath: nil,
                        browserName: browser,
                        actionType: "submit"
                    )
                )
            default:
                continue
            }
            onEventCaptured?(step)
        }
    }

    private func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
