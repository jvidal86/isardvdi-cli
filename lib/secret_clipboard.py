#!/usr/bin/env python3
"""Put a secret (read from stdin) on the clipboard the way password managers do: marked so that
clipboard histories don't keep it (KDE Klipper: x-kde-passwordManagerHint), and cleared after
--seconds if it is still there. Linux desktops only (Qt: PyQt5, PyQt6 or PySide6). The secret is
never on a command line. Forks into the background and returns at once; exit 1 if no Qt or no
clipboard to put it on."""
import argparse
import os
import sys


def qt():
    for mod in ("PyQt6", "PySide6", "PyQt5"):
        try:
            gui = __import__(mod + ".QtGui", fromlist=["QtGui"])
            core = __import__(mod + ".QtCore", fromlist=["QtCore"])
            return gui, core
        except ImportError:
            continue
    return None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=60, help="clear it after this long")
    args = ap.parse_args()
    secret = sys.stdin.readline().strip()
    if not secret:
        return 1
    gui, core = qt()
    if gui is None or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return 1
    # X11 (XWayland too): any client may own the clipboard; on Wayland only a focused window can.
    if os.environ.get("DISPLAY"):
        os.environ["QT_QPA_PLATFORM"] = "xcb"
    if os.fork():
        return 0  # the parent returns; the child keeps the clipboard alive
    os.setsid()
    devnull = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(devnull, fd)
    app = gui.QGuiApplication([sys.argv[0]])
    data = core.QMimeData()
    data.setText(secret)
    data.setData("x-kde-passwordManagerHint", core.QByteArray(b"secret"))
    cb = app.clipboard()
    cb.setMimeData(data)

    def done():
        if cb.text() == secret:
            cb.clear()
        app.quit()

    core.QTimer.singleShot(args.seconds * 1000, done)
    app.exec() if hasattr(app, "exec") else app.exec_()
    return 0


if __name__ == "__main__":
    sys.exit(main())
