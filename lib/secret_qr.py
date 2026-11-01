#!/usr/bin/env python3
"""Show a QR code image (PNG bytes on stdin, from qrencode) in a small window until a key or a
click, for a terminal too small to draw it. The image is never written to disk. Linux desktops
only (Qt: PyQt6, PySide6 or PyQt5). Exit 0 once the window is closed; exit 1 if there is no Qt,
no display, or nothing on stdin."""
import argparse
import os
import sys


def qt():
    for mod in ("PyQt6", "PySide6", "PyQt5"):
        try:
            gui = __import__(mod + ".QtGui", fromlist=["QtGui"])
            core = __import__(mod + ".QtCore", fromlist=["QtCore"])
            widgets = __import__(mod + ".QtWidgets", fromlist=["QtWidgets"])
            return gui, core, widgets
        except ImportError:
            continue
    return None, None, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", default="Scan with mIsardVDI")
    ap.add_argument("--caption", default="Press any key or click to close")
    ap.add_argument("--seconds", type=int, default=120, help="close by itself after this long")
    args = ap.parse_args()
    png = sys.stdin.buffer.read()
    if not png:
        return 1
    gui, core, widgets = qt()
    if gui is None or not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        return 1

    app = widgets.QApplication([sys.argv[0]])
    image = gui.QPixmap()
    if not image.loadFromData(png, "PNG"):
        return 1
    del png

    class Window(widgets.QWidget):
        def keyPressEvent(self, _event):
            self.close()

        def mousePressEvent(self, _event):
            self.close()

    win = Window()
    win.setWindowTitle(args.title)
    win.setStyleSheet("background: white; color: black;")
    layout = widgets.QVBoxLayout(win)
    picture = widgets.QLabel()
    picture.setPixmap(image)
    layout.addWidget(picture)
    caption = widgets.QLabel(args.caption)
    caption.setWordWrap(True)
    layout.addWidget(caption)
    win.show()
    win.raise_()
    win.activateWindow()
    core.QTimer.singleShot(args.seconds * 1000, win.close)
    app.exec() if hasattr(app, "exec") else app.exec_()
    return 0


if __name__ == "__main__":
    sys.exit(main())
