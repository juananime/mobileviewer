import XCTest
import Foundation

enum Handlers {
    private static var app = XCUIApplication()

    static func handle(line: String) -> String {
        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            return encode(["ok": false, "error": "invalid JSON"])
        }
        do {
            return encode(try dispatch(type, json))
        } catch {
            return encode(["ok": false, "error": error.localizedDescription])
        }
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
            app = XCUIApplication(bundleIdentifier: id)
            app.launch()
            return ok()

        case "stopApp":
            let id = try need(p, "bundleId")
            XCUIApplication(bundleIdentifier: id).terminate()
            return ok()

        case "tap":
            coord(p).tap()
            return ok()

        case "longPress":
            coord(p).press(forDuration: 0.8)
            return ok()

        case "doubleTap":
            coord(p).doubleTap()
            return ok()

        case "swipe":
            let x1 = p["x1"] as! Double, y1 = p["y1"] as! Double
            let x2 = p["x2"] as! Double, y2 = p["y2"] as! Double
            let dur = p["duration"] as? Double ?? 0.3
            let dist = (pow(x2 - x1, 2) + pow(y2 - y1, 2)).squareRoot()
            let vel = XCUIGestureVelocity(dist / dur)
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x1, dy: y1))
            let end = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: x2, dy: y2))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: vel, thenHoldForDuration: 0)
            return ok()

        case "inputText":
            let text = try need(p, "text")
            app.typeText(text)
            return ok()

        case "clearText":
            // Find first active text input, measure its content, delete it
            let field: XCUIElement = {
                if app.textFields.firstMatch.exists { return app.textFields.firstMatch }
                if app.secureTextFields.firstMatch.exists { return app.secureTextFields.firstMatch }
                return app.textViews.firstMatch
            }()
            if field.exists {
                let len = (field.value as? String)?.count ?? 0
                field.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.5)).tap()
                let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: len + 1)
                field.typeText(deletes)
            }
            return ok()

        case "hideKeyboard":
            // Tap the top-centre of the screen, outside the keyboard area
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()
            return ok()

        case "pressKey":
            let key = try need(p, "key")
            pressKey(key)
            return ok()

        case "back":
            // Swipe from left edge — iOS navigation gesture
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
            let end   = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: 800, thenHoldForDuration: 0)
            return ok()

        case "openLink":
            let url = try need(p, "url")
            // Open via Safari — the app under test is not involved
            let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
            safari.launch()
            let addrBar = safari.textFields["Address"].firstMatch
            addrBar.tap()
            addrBar.typeText(url + "\n")
            return ok()

        case "findByText":
            let text = try need(p, "text")
            let pred = NSPredicate(format: "label == %@ OR value == %@", text, text)
            let el = app.descendants(matching: .any).matching(pred).firstMatch
            guard el.exists else { return ["ok": false, "error": "not found"] }
            let f = el.frame
            return ["ok": true, "x": f.midX, "y": f.midY]

        case "findById":
            let id = try need(p, "id")
            let pred = NSPredicate(format: "identifier == %@", id)
            let el = app.descendants(matching: .any).matching(pred).firstMatch
            guard el.exists else { return ["ok": false, "error": "not found"] }
            let f = el.frame
            return ["ok": true, "x": f.midX, "y": f.midY]

        case "screenshot":
            let png = XCUIScreen.main.screenshot().pngRepresentation
            return ["ok": true, "data": png.base64EncodedString()]

        case "screenSize":
            let b = XCUIScreen.main.bounds
            return ["ok": true, "width": b.width, "height": b.height]

        case "quit":
            return ok()

        default:
            throw Err("unknown command: \(type)")
        }
    }

    // MARK: - Helpers

    private static func coord(_ p: [String: Any]) -> XCUICoordinate {
        let x = p["x"] as! Double
        let y = p["y"] as! Double
        return app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: x, dy: y))
    }

    private static func need(_ p: [String: Any], _ key: String) throws -> String {
        guard let v = p[key] as? String else { throw Err("missing '\(key)'") }
        return v
    }

    private static func pressKey(_ key: String) {
        switch key.lowercased() {
        case "home":
            XCUIDevice.shared.press(.home)
        case "enter", "return":
            app.typeText("\n")
        case "tab":
            app.typeText("\t")
        case "delete", "backspace":
            app.typeText(XCUIKeyboardKey.delete.rawValue)
        case "escape":
            app.typeText(XCUIKeyboardKey.escape.rawValue)
        case "up":
            app.typeText(XCUIKeyboardKey.upArrow.rawValue)
        case "down":
            app.typeText(XCUIKeyboardKey.downArrow.rawValue)
        case "left":
            app.typeText(XCUIKeyboardKey.leftArrow.rawValue)
        case "right":
            app.typeText(XCUIKeyboardKey.rightArrow.rawValue)
        default:
            app.typeText(key)
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