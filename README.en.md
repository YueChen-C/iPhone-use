# iPhone Use

**Control your iPhone from your Mac — no jailbreak required.**

[简体中文](README.md) | English

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 6.0+](https://img.shields.io/badge/Swift-6.0%2B-F05138?logo=swift&logoColor=white)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Mirror a real iPhone screen to your Mac over **USB**, then use your Mac’s mouse and keyboard to control it over **Bluetooth**. Connect an AI agent through MCP to let it see the screen and interact with your phone.

**No jailbreak. No iPhone app to install. No Apple developer account.**

[Download a release](https://github.com/YueChen-C/iPhone-use/releases) · [Features](#features) · [Quick Start](#quick-start) · [AI Integration](#ai-integration) · [Documentation](#documentation)

## Features

- 📱 **Live screen mirroring** — View your iPhone screen in a native Mac window through a wired USB connection.
- 🖱️ **Mouse and keyboard control** — Click, drag, type, and send shortcuts through Bluetooth LE HID. Your Mac acts as a Bluetooth input device.
- 🤖 **AI agent integration** — Give Codex and other MCP clients tools to take screenshots, tap, swipe, type, and inspect the result.
- 🔌 **Multiple iPhones** — Open a separate window for each device and select phones by ID through MCP or the HTTP API.
- 🔑 **Independent Apple Accounts** — Core mirroring and control do not require the Mac and iPhone to share an Apple Account or enable two-factor authentication.
- 🛠️ **Scriptable control** — Use the local HTTP API for automation, screenshots, and device management.

## Why iPhone Use?

For everyday phone control, app testing, live demos, and AI automation, iPhone Use brings a real device into your Mac workflow. It works without WebDriverAgent (WDA), signing an iPhone app, or enrolling in the Apple Developer Program.

Use devices signed into different Apple Accounts, connect multiple test phones, and switch between your Mac and the phone’s own touchscreen while the phone stays unlocked.

Unlike Apple’s [iPhone Mirroring](https://support.apple.com/en-us/120421), this project uses a USB cable for video and Bluetooth for input. Each phone needs USB trust, Bluetooth pairing, and AssistiveTouch enabled.

## How It Works

```text
iPhone screen ───── USB ────────────→ Mac window / screenshots
iPhone input  ←─── Bluetooth LE HID ─ Mac mouse, keyboard, or automation
```

The Mac captures video through AVFoundation and exposes mouse and keyboard input through Bluetooth LE HID. The HTTP API and MCP tools use the same device control layer as the desktop windows. No software is installed on the iPhone.

## Quick Start

### Requirements

| Requirement | Details |
| --- | --- |
| Mac | macOS 14 or later, with Bluetooth LE support and Bluetooth enabled |
| iPhone | Unlocked, connected with a data-capable USB cable |
| Permissions | macOS camera and Bluetooth access; USB trust and AssistiveTouch on iPhone |

### Option 1: Install a release (recommended)

**No Xcode, Swift toolchain, source checkout, or compilation required.**

1. Open [GitHub Releases](https://github.com/YueChen-C/iPhone-use/releases) and download `iPhoneUse-v<version>-macOS-universal.zip` from the chosen release's **Assets**. The same ZIP supports Apple Silicon and Intel Macs. The `Source code` downloads contain source files rather than the app.
2. Unzip the archive and drag `iPhoneUse.app` into Applications (`/Applications`).
3. Double-click the app to open it. Automated builds are ad-hoc signed and are not notarized. If macOS blocks the app, verify the download source and follow the prompts in **System Settings → Privacy & Security** to allow it.
4. Follow [Connect and pair your iPhone](#connect-and-pair-your-iphone) below to complete USB trust, camera and Bluetooth permissions, and AssistiveTouch pairing. You can then use your Mac's mouse and keyboard to control the phone.

To verify the archive, download the ZIP and `SHA256SUMS.txt` from the same release into one folder and run this command there:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

For later use, connect and unlock your iPhone, then open `iPhoneUse.app`. Everyday use requires no terminal commands. To let an AI agent operate the phone, continue to [AI Integration](#ai-integration).

### Option 2: Build from source

Install Swift 6.0 or later through Xcode or compatible Command Line Tools. The Swift app uses system frameworks and has no third-party Swift package dependencies.

```sh
git clone https://github.com/YueChen-C/iPhone-use.git
cd iPhone-use
./scripts/run.sh
```

The script builds a Release executable, opens the control window, and starts the local HTTP service at `http://127.0.0.1:7390`. Local use needs no manual code signing or `.app` packaging.

### Connect and pair your iPhone

1. Connect the iPhone over USB, unlock it, and tap **Trust This Computer**. Allow the accessory connection on your Mac if prompted.
2. Grant **Camera** and **Bluetooth** permissions on macOS. Camera access is used to capture the USB video feed.
3. On the iPhone, open **Settings → Accessibility → Touch → AssistiveTouch** and turn on **AssistiveTouch**.
4. On that page, open **Devices → Bluetooth Devices**, select **iPhone Use** or the Mac name shown in the control window, and confirm pairing on both devices when prompted.
5. Wait for the screen and control connection to become ready, then use your Mac’s mouse and keyboard in the phone window.

Keep the app running while using MCP or the API. By default, closing the last window exits the app and stops the service; enable **iPhone Use → Quiet Background Mode** (or launch with `--resident-quiet`) to keep the service running after closing windows and suppress automatic window pop-ups on launch or USB connection whenever no unminimized waiting window is open (an already-open unminimized waiting window transitions in place to connected device windows).

## AI Integration

### Codex

With the Codex CLI installed, users of the downloaded app can register it directly:

```sh
codex mcp add iphone-use -- /Applications/iPhoneUse.app/Contents/MacOS/iphone-use mcp
```

For a source checkout, run these commands from the repository root in another terminal:

```sh
./scripts/install-codex-mcp.sh
./scripts/install-codex-skill.sh
```

For source installs, the first script builds and registers the local MCP server. The second installs the optional `$iphone-use` skill for reusable phone tasks. Downloaded builds can use MCP directly; the skill and automatic recovery currently depend on the source build directory. For either installation, keep the main app running, then open a new Codex chat or restart Codex to load the tools.

Try a task. If you installed the optional skill, you can prefix it with `$iphone-use`:

```text
Open Settings → General → About and read the iOS version.
```

You can also ask the agent to list connected iPhones, take a screenshot, and follow your instructions. For a live, read-only preview, open `http://127.0.0.1:7390/viewer` in the Codex browser or another local browser.

### Other MCP clients

After installing the downloaded app in Applications, add this stdio server to your client's MCP configuration:

```json
{
  "mcpServers": {
    "iphone-use": {
      "command": "/Applications/iPhoneUse.app/Contents/MacOS/iphone-use",
      "args": ["mcp"]
    }
  }
}
```

For a source install, run `swift build -c release` and set `command` to the absolute path to `.build/release/iphone-use` in your checkout.

MCP mode forwards requests to the running app; it does not start screen capture or Bluetooth itself. Both the app and the MCP server must run on the Mac connected to the iPhone.

## HTTP API

Use the local API from your own scripts while the app is running:

```sh
# List connected devices
curl -s http://127.0.0.1:7390/devices

# Save a screenshot
curl -s http://127.0.0.1:7390/screenshot -o screen.jpg

# Tap the center of the screen using normalized coordinates
curl -s http://127.0.0.1:7390/tap \
  -H 'Content-Type: application/json' \
  -d '{"x":0.5,"y":0.5,"fraction":true}'
```

When multiple phones are connected, specify the full device ID: use `?device=<id>` for GET requests and a `"device"` field in POST JSON. The service listens only on the local loopback address. See the [API reference](docs/user-guide.md#http-api) for endpoints and coordinate formats.

## Things to Know

- **Device state:** Keep the iPhone unlocked. Portrait orientation is the primary workflow; landscape and dynamic rotation are not guaranteed.
- **Pointer accuracy:** Some devices need [pointer calibration](docs/user-guide.md#指针校准). Results vary with the device, iOS version, and pointer settings.
- **Text input:** Direct typing supports ASCII through a US keyboard layout. Other text requires a configured iPhone input method or Apple Universal Clipboard; clipboard sharing follows Apple’s own requirements.
- **Connection issues:** If video works but input does not, check Bluetooth pairing and AssistiveTouch. Use `/status` to inspect the connection, or consult [troubleshooting](docs/user-guide.md#常见问题与限制).

## Documentation

| Guide | Contents |
| --- | --- |
| [User guide (中文)](docs/user-guide.md) | Window controls, MCP setup, API reference, calibration, multi-device pairing, recording, and troubleshooting |
| [Architecture (中文)](docs/architecture.md) | Modules, shared state, queues, and maintenance constraints |
| [Agent skill (中文)](codex/skills/iphone-use/SKILL.md) | Reusable phone workflows for Codex |
| [Release guide (中文)](docs/releasing.md) | Automated GitHub Releases, universal packaging, versions, and signing |

## Development

```sh
swift test
swift build -c release
python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'
python3 -B scripts/check-mcp.py
```

Hardware changes also need real-device checks for pairing, USB reconnection, pointer accuracy, and window interaction. See the [architecture guide](docs/architecture.md) for formatting and maintenance conventions.

## License

[MIT](LICENSE)
