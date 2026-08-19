# SPDX-License-Identifier: AGPL-3.0-or-later
import argparse
import threading

import cv2
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Cam:
    def __init__(self, source: str):
        self.cap = cv2.VideoCapture(source)
        self.lock = threading.Lock()

    def read(self):
        with self.lock:
            ok, frame = self.cap.read()
        if not ok:
            self.cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
            with self.lock:
                ok, frame = self.cap.read()
            if not ok:
                return None
        return frame


def make_handler(cam: Cam, quality: int, fps: float):

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            delay = 1.0 / fps
            try:
                while True:
                    frame = cam.read()
                    if frame is None:
                        break
                    ok, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
                    if not ok:
                        continue
                    self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n")
                    self.wfile.write(buf.tobytes())
                    self.wfile.write(b"\r\n")
                    if delay > 0:
                        threading.Event().wait(delay)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

        def log_message(self, *args):
            pass

    return Handler


def main() -> int:
    ap = argparse.ArgumentParser(description="Serve a looped video as a live MJPEG 'CCTV' URL source.")
    ap.add_argument("--source", default="test_video.mp4")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--fps", type=float, default=25.0)
    ap.add_argument("--quality", type=int, default=70)
    args = ap.parse_args()

    cam = Cam(args.source)
    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(cam, args.quality, args.fps))
    print(f"serving {args.source} live at http://127.0.0.1:{args.port}/video.mjpg  (Ctrl+C to stop)")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())