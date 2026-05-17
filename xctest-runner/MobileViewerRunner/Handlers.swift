import XCTest
import Foundation

enum Handlers {
    // Nil until a "connect" or "launchApp" command provides a bundle ID.
    // Avoids calling XCUIApplication() with no args, which requires a target
    // app baked into the test configuration.
    private static var app: XCUIApplication?

    private static func getApp() throws -> XCUIApplication {
        guard let a = app else {
            throw Err("no target app — send 'connect' or 'launchApp' with bundleId first")
        }
        return a
    }

    static func handle(line: String) -> String {
        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return encode(["ok": false, "error": "invalid JSON"])
        }
        // XCUIApplication requires the main thread. The test's wait(for:timeout:)
        // runs the main run loop, so async blocks dispatched here will execute.
        // We block the socket thread with a semaphore until the result is ready.
        let sema = DispatchSemaphore(value: 0)
        var result = ""
        DispatchQueue.main.async {
            do {
                result = encode(try dispatch(type, json))
            } catch {
                result = encode(["ok": false, "error": error.localizedDescription])
            }
            sema.signal()
        }
        sema.wait()
        return result
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private static func dispatch(_ type: String, _ p: [String: Any]) throws -> [String: Any] {
        switch type {

        case "connect":
            if let id = p["bundleId"] as? String, !id.isEmpty {
                app = XCUIApplication(bundleIdentifier: id)
            }
            return ok()

        case "launchApp":
            let id = try need(p, "bundleId")
            let a = XCUIApplication(bundleIdentifier: id)
            app = a
            a.launch()
            return ok()

        case "stopApp":
            let id = try need(p, "bundleId")
            XCUIApplication(bundleIdentifier: id).terminate()
            return ok()

        case "tap":
            try coord(p).tap()
            return ok()

        case "longPress":
            try coord(p).press(forDuration: 0.8)
            return ok()

        case "doubleTap":
            try coord(p).doubleTap()
            return ok()

        case "swipe":
            let x1 = p["x1"] as! Double, y1 = p["y1"] as! Double
            let x2 = p["x2"] as! Double, y2 = p["y2"] as! Double
            let dur = p["duration"] as? Double ?? 0.3
            let dist = (pow(x2 - x1, 2) + pow(y2 - y1, 2)).squareRoot()
            let vel = XCUIGestureVelocity(rawValue: CGFloat(dist / dur))
            let a = try getApp()
            let start = a.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x1, dy: y1))
            let end = a.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x2, dy: y2))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: vel, thenHoldForDuration: 0)
            return ok()

        case "inputText":
            let text = try need(p, "text")
            try getApp().typeText(text)
            return ok()

        case "clearText":
            let a = try getApp()
            let field: XCUIElement = {
                if a.textFields.firstMatch.exists { return a.textFields.firstMatch }
                if a.secureTextFields.firstMatch.exists { return a.secureTextFields.firstMatch }
                return a.textViews.firstMatch
            }()
            if field.exists {
                let len = (field.value as? String)?.count ?? 0
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
                let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: len + 1)
                field.typeText(deletes)
            }
            return ok()

        case "hideKeyboard":
            try getApp().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            return ok()

        case "pressKey":
            let key = try need(p, "key")
            try pressKey(key)
            return ok()

        case "back":
            let a = try getApp()
            let start = a.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            let end   = a.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: 800, thenHoldForDuration: 0)
            return ok()

        case "openLink":
            let url = try need(p, "url")
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            safari.launch()
            let addrBar = safari.textFields["Address"].firstMatch
            addrBar.tap()
            addrBar.typeText(url + "\n")
            return ok()

        case "findByText":
            let text = try need(p, "text")
            let pred = NSPredicate(format: "label == %@ OR value == %@", text, text)
            let el = try getApp().descendants(matching: .any).matching(pred).firstMatch
            guard el.exists else { return ["ok": false, "error": "not found"] }
            let f = el.frame
            return ["ok": true, "x": f.midX, "y": f.midY]

        case "findById":
            let id = try need(p, "id")
            let pred = NSPredicate(format: "identifier == %@", id)
            let el = try getApp().descendants(matching: .any).matching(pred).firstMatch
            guard el.exists else { return ["ok": false, "error": "not found"] }
            let f = el.frame
            return ["ok": true, "x": f.midX, "y": f.midY]

        case "screenshot":
            let png = XCUIScreen.main.screenshot().pngRepresentation
            return ["ok": true, "data": png.base64EncodedString()]

        case "screenSize":
            let b = try getApp().frame
            return ["ok": true, "width": b.width, "height": b.height]

        case "quit":
            return ok()

        default:
            throw Err("unknown command: \(type)")
        }
    }

    // MARK: - Helpers

    private static func coord(_ p: [String: Any]) throws -> XCUICoordinate {
        let x = p["x"] as! Double
        let y = p["y"] as! Double
        return try getApp().coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
    }

    private static func need(_ p: [String: Any], _ key: String) throws -> String {
        guard let v = p[key] as? String else { throw Err("missing '\(key)'") }
        return v
    }

    private static func pressKey(_ key: String) throws {
        let a = try getApp()
        switch key.lowercased() {
        case "home":
            XCUIDevice.shared.press(.home)
        case "enter", "return":
            a.typeText("\n")
        case "tab":
            a.typeText("\t")
        case "delete", "backspace":
            a.typeText(XCUIKeyboardKey.delete.rawValue)
        case "escape":
            a.typeText(XCUIKeyboardKey.escape.rawValue)
        case "up":
            a.typeText(XCUIKeyboardKey.upArrow.rawValue)
        case "down":
            a.typeText(XCUIKeyboardKey.downArrow.rawValue)
        case "left":
            a.typeText(XCUIKeyboardKey.leftArrow.rawValue)
        case "right":
            a.typeText(XCUIKeyboardKey.rightArrow.rawValue)
        default:
            a.typeText(key)
        }
    }

    private static func ok() -> [String: Any] { ["ok": true] }

    private static func encode(_ d: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: d),
            let str = String(data: data, encoding: .utf8)
        else { return #"{"ok":false,"error":"encode error"}"# }
        return str
    }
}