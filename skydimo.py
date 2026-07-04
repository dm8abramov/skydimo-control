#!/usr/bin/env python3
import argparse
import math
import os
import sys
import termios
import time


DEFAULT_PORT = "auto"
DEFAULT_LEDS = 65
DEFAULT_BAUDRATE = 115200
DEFAULT_FPS = 80
RED_CALIBRATION = 1.0
GREEN_CALIBRATION = 0.72
BLUE_CALIBRATION = 0.25
BAUDRATES = {115200: termios.B115200}
PORT_PREFIXES = (
    "cu.usbserial",
    "cu.wchusbserial",
    "cu.SLAB_USBtoUART",
    "cu.usbmodem",
)


def parse_hex_color(value):
    value = value.strip()
    if value.startswith("#"):
        value = value[1:]
    if len(value) != 6:
        raise argparse.ArgumentTypeError("color must be RRGGBB or #RRGGBB")
    try:
        return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("color must be hexadecimal") from exc


def serial_port_candidates(port):
    if port != "auto":
        return [port]

    try:
        names = os.listdir("/dev")
    except OSError:
        names = []

    return [
        f"/dev/{name}"
        for prefix in PORT_PREFIXES
        for name in sorted(names)
        if name.startswith(prefix)
    ]


def open_serial(port):
    candidates = serial_port_candidates(port)
    if not candidates:
        raise FileNotFoundError(
            "SkyDimo serial port was not found. Tried /dev/cu.usbserial*, "
            "/dev/cu.wchusbserial*, /dev/cu.SLAB_USBtoUART*, /dev/cu.usbmodem*."
        )

    errors = []
    for path in candidates:
        try:
            return configure_serial(path)
        except OSError as exc:
            errors.append(f"{path}: {exc.strerror or exc}")

    raise OSError("Could not open SkyDimo serial port. Tried:\n" + "\n".join(errors))


def configure_serial(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)

    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = attrs
    iflag = termios.IGNPAR
    oflag = 0
    lflag = 0
    cflag = termios.CS8 | termios.CLOCAL | termios.CREAD
    ispeed = BAUDRATES[DEFAULT_BAUDRATE]
    ospeed = BAUDRATES[DEFAULT_BAUDRATE]

    if hasattr(termios, "CRTSCTS"):
        cflag &= ~termios.CRTSCTS
    cflag &= ~termios.PARENB
    cflag &= ~termios.CSTOPB
    cflag &= ~termios.CSIZE
    cflag |= termios.CS8

    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1

    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, ispeed, ospeed, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def write_all(fd, payload):
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        view = view[written:]


def make_frame(leds, rgb, order):
    rgb = calibrate_rgb(rgb)
    channels = {"r": rgb[0], "g": rgb[1], "b": rgb[2]}
    pixel = bytes(channels[channel] for channel in order)
    return make_pixels_frame(leds, [pixel] * leds)


def calibrate_rgb(rgb):
    return (
        round(clamp(rgb[0] * RED_CALIBRATION, 0, 255)),
        round(clamp(rgb[1] * GREEN_CALIBRATION, 0, 255)),
        round(clamp(rgb[2] * BLUE_CALIBRATION, 0, 255)),
    )


def make_pixels_frame(leds, pixels):
    if len(pixels) != leds:
        raise ValueError(f"expected {leds} pixels, got {len(pixels)}")
    header = b"Ada" + bytes((0, (leds >> 8) & 0xFF, leds & 0xFF))
    return header + b"".join(pixels)


def stream_color(port, payload, seconds, fps):
    fd = open_serial(port)
    try:
        frame_delay = 1 / fps
        started_at = time.monotonic()
        while seconds == 0 or time.monotonic() - started_at < seconds:
            write_all(fd, payload)
            termios.tcdrain(fd)
            time.sleep(frame_delay)
    finally:
        os.close(fd)


def send_color(args):
    payload = make_frame(args.leds, args.color, args.order)
    stream_color(args.port, payload, args.seconds, args.fps)


def turn_off(args):
    payload = make_frame(args.leds, (0, 0, 0), args.order)
    stream_color(args.port, payload, args.seconds, args.fps)


def hsv_to_rgb(hue, saturation, value):
    hue = hue % 1.0
    chroma = value * saturation
    segment = hue * 6
    x = chroma * (1 - abs(segment % 2 - 1))

    if segment < 1:
        r, g, b = chroma, x, 0
    elif segment < 2:
        r, g, b = x, chroma, 0
    elif segment < 3:
        r, g, b = 0, chroma, x
    elif segment < 4:
        r, g, b = 0, x, chroma
    elif segment < 5:
        r, g, b = x, 0, chroma
    else:
        r, g, b = chroma, 0, x

    match = value - chroma
    return (
        round((r + match) * 255),
        round((g + match) * 255),
        round((b + match) * 255),
    )


def ordered_pixel(rgb, order):
    rgb = calibrate_rgb(rgb)
    channels = {"r": rgb[0], "g": rgb[1], "b": rgb[2]}
    return bytes(channels[channel] for channel in order)


def send_rainbow(args):
    fd = open_serial(args.port)
    try:
        frame_delay = 1 / args.fps
        started_at = time.monotonic()
        while args.seconds == 0 or time.monotonic() - started_at < args.seconds:
            elapsed = time.monotonic() - started_at
            offset = elapsed * args.speed
            pixels = [
                ordered_pixel(
                    hsv_to_rgb(index / args.leds * args.cycles + offset, args.saturation, args.brightness),
                    args.order,
                )
                for index in range(args.leds)
            ]
            write_all(fd, make_pixels_frame(args.leds, pixels))
            termios.tcdrain(fd)
            time.sleep(frame_delay)
    finally:
        os.close(fd)


def mix_rgb(a, b, amount):
    return tuple(round(a[i] + (b[i] - a[i]) * amount) for i in range(3))


def clamp(value, minimum, maximum):
    return max(minimum, min(maximum, value))


def flame_rgb(heat, brightness):
    heat = clamp(heat, 0, 1)
    palette = (
        (55, 6, 0),
        (170, 28, 0),
        (255, 78, 0),
        (255, 135, 8),
        (255, 190, 42),
    )
    position = heat * (len(palette) - 1)
    index = min(int(position), len(palette) - 2)
    color = mix_rgb(palette[index], palette[index + 1], position - index)
    return tuple(round(channel * brightness) for channel in color)


def send_flame(args):
    fd = open_serial(args.port)
    try:
        frame_delay = 1 / args.fps
        started_at = time.monotonic()
        while args.seconds == 0 or time.monotonic() - started_at < args.seconds:
            elapsed = time.monotonic() - started_at
            pixels = []
            for index in range(args.leds):
                x = index / max(args.leds - 1, 1)
                wave = (
                    0.55 * math.sin((x * 9.0 + elapsed * args.speed * 2.3) * math.tau)
                    + 0.30 * math.sin((x * 17.0 - elapsed * args.speed * 3.7) * math.tau)
                    + 0.15 * math.sin((x * 31.0 + elapsed * args.speed * 5.1) * math.tau)
                )
                flicker = 0.5 + 0.5 * wave
                base = 0.48 + args.intensity * 0.22
                edge_fade = 0.88 + 0.12 * math.sin((x + elapsed * args.speed * 0.35) * math.tau)
                heat = clamp((base + flicker * args.flicker) * edge_fade, 0, 1)
                pixels.append(ordered_pixel(flame_rgb(heat, args.brightness), args.order))

            write_all(fd, make_pixels_frame(args.leds, pixels))
            termios.tcdrain(fd)
            time.sleep(frame_delay)
    finally:
        os.close(fd)


def build_parser():
    parser = argparse.ArgumentParser(description="Control a SkyDimo USB monitor backlight.")
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--leds", type=int, default=DEFAULT_LEDS)
    parser.add_argument("--order", choices=("rgb", "rbg", "grb", "gbr", "brg", "bgr"), default="rgb")

    subparsers = parser.add_subparsers(dest="command", required=True)

    color = subparsers.add_parser("color", help="Set and hold a color.")
    color.add_argument("color", type=parse_hex_color, help="Color as RRGGBB or #RRGGBB.")
    color.add_argument("--seconds", type=float, default=0, help="Hold for N seconds. Use 0 until Ctrl-C.")
    color.add_argument("--fps", type=float, default=DEFAULT_FPS)
    color.set_defaults(func=send_color)

    off = subparsers.add_parser("off", help="Turn the strip off.")
    off.add_argument("--seconds", type=float, default=1)
    off.add_argument("--fps", type=float, default=DEFAULT_FPS)
    off.set_defaults(func=turn_off)

    rainbow = subparsers.add_parser("rainbow", help="Run a flowing rainbow effect.")
    rainbow.add_argument("--seconds", type=float, default=0, help="Run for N seconds. Use 0 until Ctrl-C.")
    rainbow.add_argument("--fps", type=float, default=DEFAULT_FPS)
    rainbow.add_argument("--speed", type=float, default=0.25, help="Rainbow rotations per second.")
    rainbow.add_argument("--cycles", type=float, default=1.0, help="Rainbow cycles across the strip.")
    rainbow.add_argument("--brightness", type=float, default=1.0)
    rainbow.add_argument("--saturation", type=float, default=1.0)
    rainbow.set_defaults(func=send_rainbow)

    flame = subparsers.add_parser("flame", help="Run a warm candle/flame effect.")
    flame.add_argument("--seconds", type=float, default=0, help="Run for N seconds. Use 0 until Ctrl-C.")
    flame.add_argument("--fps", type=float, default=DEFAULT_FPS)
    flame.add_argument("--speed", type=float, default=0.7, help="Flicker speed.")
    flame.add_argument("--brightness", type=float, default=0.75)
    flame.add_argument("--flicker", type=float, default=0.28, help="Flicker amount from 0 to 1.")
    flame.add_argument("--intensity", type=float, default=0.45, help="Heat amount from 0 to 1.")
    flame.set_defaults(func=send_flame)

    return parser


def main():
    parser = build_parser()
    args = parser.parse_args()
    if args.leds <= 0:
        parser.error("--leds must be positive")
    if hasattr(args, "fps") and args.fps <= 0:
        parser.error("--fps must be positive")
    if hasattr(args, "brightness") and not 0 <= args.brightness <= 1:
        parser.error("--brightness must be between 0 and 1")
    if hasattr(args, "saturation") and not 0 <= args.saturation <= 1:
        parser.error("--saturation must be between 0 and 1")
    if hasattr(args, "flicker") and not 0 <= args.flicker <= 1:
        parser.error("--flicker must be between 0 and 1")
    if hasattr(args, "intensity") and not 0 <= args.intensity <= 1:
        parser.error("--intensity must be between 0 and 1")
    if hasattr(args, "cycles") and args.cycles <= 0:
        parser.error("--cycles must be positive")
    if hasattr(args, "speed") and args.speed < 0:
        parser.error("--speed must be non-negative")
    try:
        args.func(args)
    except OSError as exc:
        print(f"USB serial error: {exc}", file=sys.stderr)
        return 1
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
