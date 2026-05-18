# mobileviewer

A lightweight Dart CLI for running E2E tests on Flutter (and any native) iOS and Android apps. Tests are written in YAML using a [Maestro](https://maestro.mobile.dev/)-compatible syntax. iOS automation is powered by XCTest/XCUIApplication; Android automation uses adb + UIAutomator — no extra test frameworks or cloud services required.

---

## Prerequisites

### iOS
- macOS with Xcode 14+ installed
- At least one iOS Simulator configured (`xcrun simctl list`)
- `xcodebuild` and `xcrun` on your `PATH` (included with Xcode)

### Android
- `adb` on your `PATH` (part of Android SDK platform-tools)
- A connected device or a running emulator
- Optional: `emulator` to launch AVDs from the CLI
- Optional: `scrcpy` to mirror the device screen

### Dart SDK
- Dart 3.x (`dart --version`)

---

## Installation

```bash
# 1. Clone the repo
git clone <repo-url>
cd mobileviewer

# 2. Install Dart dependencies
dart pub get
```

---

## Global installation

### Option 1 — compile to a native binary (recommended)

Produces a self-contained executable with no Dart runtime dependency.

```bash
dart compile exe bin/mobileviewer.dart -o mobileviewer
sudo mv mobileviewer /usr/local/bin/mobileviewer

# Verify
mobileviewer --help
```

### Option 2 — `dart pub global activate`

Installs a wrapper script via the Dart pub cache. Requires Dart to be present on the target machine.

```bash
# From the project root
dart pub global activate --source path .
```

Then ensure `~/.pub-cache/bin` is on your `PATH` (add to `~/.zshrc` if missing):

```bash
export PATH="$HOME/.pub-cache/bin:$PATH"
source ~/.zshrc

# Verify
mobileviewer --help
```

> **Which to choose?** Option 1 is better for sharing or CI pipelines — the binary runs anywhere without Dart installed. Option 2 is more convenient during development since it always reflects the latest source without recompiling.

---

## Writing a test flow

Create a `.yaml` file with two documents separated by `---`:

```yaml
# Document 1 — flow configuration
appId: com.example.myapp

---

# Document 2 — steps
- launchApp

- assertVisible: "Welcome"

- tapOn: "Login"

- inputText: "user@example.com"

- pressKey: Tab

- inputText: "secret123"

- pressKey: Enter

- wait:
    maxDuration: 2000

- assertVisible: "Home"

- takeScreenshot: after_login
```

### Available steps

| Step | Description |
|---|---|
| `launchApp` | Launch the app defined in `appId` |
| `stopApp` | Stop the app |
| `clearState` | Wipe the app's data container |
| `tapOn: "Text"` | Tap an element by visible label |
| `tapOn: {id: "accessibility-id"}` | Tap by accessibility identifier |
| `tapOn: {point: "50%, 80%"}` | Tap at a screen coordinate |
| `longPressOn` | Long-press (same target options as `tapOn`) |
| `doubleTapOn` | Double-tap (same target options as `tapOn`) |
| `swipe: {direction: UP\|DOWN\|LEFT\|RIGHT}` | Swipe in a direction |
| `swipe: {start: "x,y", end: "x,y"}` | Swipe between two coordinates |
| `scroll` | Scroll down one page |
| `scrollUntilVisible: "Text"` | Scroll until an element is visible |
| `inputText: "hello"` | Type text into the focused field |
| `clearText` | Clear the focused text field |
| `hideKeyboard` | Dismiss the keyboard |
| `pressKey: enter\|tab\|back\|home\|…` | Press a key |
| `openLink: "https://…"` | Open a URL in the browser |
| `back` | Navigate back |
| `assertVisible: "Text"` | Fail if the element is not visible |
| `assertNotVisible: "Text"` | Fail if the element is visible |
| `takeScreenshot: name` | Save a PNG screenshot |
| `wait: {maxDuration: 1000}` | Wait in milliseconds |
| `waitForAnimationToEnd` | Wait 800 ms for animations to settle |
| `repeat: {times: 3, commands: […]}` | Repeat a list of steps |
| `runFlow: path/to/other.yaml` | Run another flow file |

---

## Running tests

```bash
# iOS simulator
dart run bin/mobileviewer.dart --ios flow.yaml

# iOS — install a local .app first, then run the flow
dart run bin/mobileviewer.dart --ios --app path/to/MyApp.app flow.yaml

# Android
dart run bin/mobileviewer.dart --android flow.yaml

# Show verbose output (xcodebuild / runner logs)
dart run bin/mobileviewer.dart --ios --verbose flow.yaml

# Help
dart run bin/mobileviewer.dart --help
```

If using the compiled binary replace `dart run bin/mobileviewer.dart` with `./mobileviewer`.

### iOS — first run

The first time you run an iOS flow the XCTest runner bundle is compiled automatically (takes ~1 min). Subsequent runs reuse the cached build.

### Selecting a device

If more than one simulator / device is available you will be prompted to pick one interactively. Boot your preferred simulator before running to skip the prompt:

```bash
xcrun simctl boot "iPhone 16"
```

---

## CLI reference

```
Usage: mobileviewer --ios|--android [options] [flow.yaml]

Platform (required):
  --ios              Target an iOS simulator
  --android          Target an Android device or emulator

Options:
  --app <path>       Path to a .app bundle to install before running (iOS only)
  --verbose, -v      Stream raw xcodebuild / runner output (hidden by default)
  --help, -h         Show this help message
```