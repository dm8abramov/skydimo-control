# SkyDimo USB Backlight Control

Native macOS menu bar app and fallback CLI for controlling a SkyDimo monitor backlight connected as a CH340 USB serial device.

Confirmed settings for this machine:

- Port: auto-detected from `/dev/cu.usbserial*`, `/dev/cu.wchusbserial*`, `/dev/cu.SLAB_USBtoUART*`, or `/dev/cu.usbmodem*`
- Baudrate: `115200`
- LED count: `65`
- Protocol: `Ada` + LED count + RGB bytes
- Default FPS: `60`
- Color calibration: red `1.0`, green `0.72`, blue `0.25`

## Requirements

Close the official SkyDimo app before running this tool. The USB serial port can be used by only one process at a time.

The menu bar app is native Swift and does not depend on Python.

## Menu Bar App

Quick install:

```sh
./install.command
```

You can also double-click `install.command` in Finder. It builds the app, installs it to the Applications folder, registers autostart, and starts the menu bar app.

The macOS menu bar app is here:

```sh
MenuBarApp/build/SkyDimoBar.app
```

Open it:

```sh
open MenuBarApp/build/SkyDimoBar.app
```

It adds a flame icon to the top menu bar. The menu is grouped as `Static Colors` first, then `Animations`, then utility actions: `Off`, `Stop Current Mode`, and `Quit SkyDimo`.

The control panel has:

- mode selector: custom color, candle, amber, warm white, neutral white, red, soft flame, rainbow
- native macOS color picker
- brightness slider
- speed slider
- flicker slider
- heat slider
- FPS slider
- apply, off, and stop buttons

The app auto-detects the USB serial port and talks to it directly using the SkyDimo serial protocol. It does not launch `python3` or `skydimo.py`.

The output is color-calibrated because the strip's blue channel is visually too strong. This keeps white warmer and makes flame effects look less cold.

On launch, the app restores the last selected menu preset and sends it to the strip immediately. Choosing `Off` clears that startup preset.

Manual rebuild after editing Swift code:

```sh
./MenuBarApp/build.sh
```

Manual install and autostart registration:

```sh
./MenuBarApp/install-launchagent.sh
```

Remove autostart and uninstall the app:

```sh
./MenuBarApp/uninstall-launchagent.sh
```

The LaunchAgent file is generated during install in the current user's LaunchAgents directory.

## Python CLI

The Python CLI is kept as a fallback/debug tool.

Turn on a color and keep it until `Ctrl-C`:

```sh
python3 skydimo.py color '#ff0000'
```

Hold a color for a fixed time:

```sh
python3 skydimo.py color '#00ff00' --seconds 30
python3 skydimo.py color '#0000ff' --seconds 30
python3 skydimo.py color '#ffffff' --seconds 30
```

Turn the strip off:

```sh
python3 skydimo.py off
```

Run a flowing rainbow until `Ctrl-C`:

```sh
python3 skydimo.py rainbow
```

Run a slower or faster rainbow:

```sh
python3 skydimo.py rainbow --speed 0.1
python3 skydimo.py rainbow --speed 0.6
```

Limit brightness:

```sh
python3 skydimo.py rainbow --brightness 0.4
```

Run a warm flame effect until `Ctrl-C`:

```sh
python3 skydimo.py flame
```

Softer candle-like flame:

```sh
python3 skydimo.py flame --brightness 0.45 --flicker 0.18 --speed 0.45
```

Brighter active flame:

```sh
python3 skydimo.py flame --brightness 0.9 --flicker 0.4 --speed 1.0
```

## Options

By default the CLI auto-detects the serial port:

```sh
python3 skydimo.py color '#ff0000'
```

For diagnostics, you can still force a specific serial device:

```sh
python3 skydimo.py --port /dev/cu.YOUR_SERIAL_DEVICE color '#ff0000'
```

Use another LED count:

```sh
python3 skydimo.py --leds 71 color '#ff0000'
```

If colors are swapped on another controller, change channel order:

```sh
python3 skydimo.py --order grb color '#ff0000'
```

## Notes

The program keeps sending frames while the color is active. If it stops, the controller may turn the strip off after a short timeout.
