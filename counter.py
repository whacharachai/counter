# SPDX-License-Identifier: AGPL-3.0-or-later
import argparse
import os
import sys
from urllib.parse import urlparse

import cv2
import torch
from ultralytics import YOLO


def main() -> int:
    ap = argparse.ArgumentParser(
        prog="counter.py",
        description=(
            "Count people in a video, camera, or live stream using YOLO detection + tracking.\n"
            "  line   - number each person as they cross a virtual line (default); reports\n"
            "            in/out separately, --in-direction sets which way is 'in', and\n"
            "            --count in|out counts only one direction\n"
            "  appear - number every person who enters the frame\n"
            "Numbers are kept unique and stable: they are only reused when the same person's\n"
            "track briefly drops out and reappears nearby, never for someone who left the\n"
            "frame at the edge. A cropped snapshot of each counted person is saved into a\n"
            "folder named after the video, the total is always written to <source>_counter.txt,\n"
            "and a progress bar shows elapsed/total time. --stride N skips frames for speed,\n"
            "--half enables faster fp16 GPU inference."
        ),
        epilog="Examples:\n  counter.py --source video.mp4 --show --save\n"
               "  counter.py --source video.mp4 --mode appear --show\n"
               "  counter.py --source video.mp4 --mode line --count in --show\n"
               "  counter.py --source 0 --show",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--source", default="0", help="video file path or camera index (default: 0)")
    ap.add_argument("--model", default="yolov8n.pt", help="YOLO model file (downloaded on first use)")
    ap.add_argument("--device", default=None, help="inference device, e.g. 0 or cuda:0 for GPU, cpu (default: auto)")
    ap.add_argument("--tracker", default=None, help="tracker config yaml (e.g. cfg/bytetrack_strong.yaml keeps IDs longer in crowds; used automatically when --stride is >1)")
    ap.add_argument("--line", type=float, default=0.5, help="counting line position as fraction of the chosen axis (0-1)")
    ap.add_argument("--line-axis", choices=("horizontal", "vertical"), default="horizontal",
                    help="line orientation (default: horizontal)")
    ap.add_argument("--in-direction", choices=("top-to-bottom", "bottom-to-top",
                    "left-to-right", "right-to-left"), default=None,
                    help="which crossing direction counts as 'in' in line mode "
                         "(default: top-to-bottom for a horizontal line, left-to-right for vertical)")
    ap.add_argument("--count", choices=("both", "in", "out"), default="both",
                    help="line mode: count crossings in both directions, only entering (in), "
                         "or only leaving (out) (default: both)")
    ap.add_argument("--mode", choices=("line", "appear"), default="line",
                    help="line: count tracks crossing the line; appear: number every person who appears (default: line)")
    ap.add_argument("--appear-seconds", type=float, default=None,
                    help="how long a person must stay visible before counted, in seconds (default: auto 0.25)")
    ap.add_argument("--merge-seconds", type=float, default=None,
                    help="grace period in seconds to reuse a person's number when a track reappears nearby (default: auto 0.8)")
    ap.add_argument("--merge-gap", type=float, default=None,
                    help="max merge distance as fraction of video width (default: auto-estimated from person size)")
    ap.add_argument("--conf", type=float, default=0.25, help="detection confidence threshold (default: 0.25)")
    ap.add_argument("--min-size", type=float, default=0.0,
                    help="ignore detections whose smaller box side is below this fraction of the frame's "
                         "shorter side (e.g. 0.05 = ignore people smaller than 5% of the frame height); "
                         "0 disables (default: 0)")
    ap.add_argument("--imgsz", type=int, default=640, help="inference image size (default: 640)")
    ap.add_argument("--stride", type=int, default=1,
                    help="process every Nth frame (e.g. 3 = about 3x faster, with skipped frames not decoded). "
                         "When >1 the stronger tracker (cfg/bytetrack_strong.yaml) is used automatically to avoid re-counts")
    ap.add_argument("--half", action="store_true",
                    help="use fp16 half-precision inference on GPU (faster, same accuracy; ignored on CPU)")
    ap.add_argument("--show", action="store_true", help="show the annotated video in a window")
    ap.add_argument("--max-frames", type=int, default=0,
                    help="stop after N frames (0 = unlimited; use for live streams)")
    ap.add_argument("--save", action="store_true",
                    help="save annotated result to <source>_counted.mp4 (counts are always written to <source>_counter.txt)")
    ap.add_argument("--no-snapshots", action="store_true",
                    help="disable saving a cropped jpg of each counted person into a folder named after the video (on by default; files are named <id>_MM_SS.jpg, e.g. 7_01_23.jpg, where the time is the position in the video)")
    ap.add_argument("--rtsp-tcp", action="store_true",
                    help="force TCP transport for RTSP streams (more reliable on Windows than default UDP)")
    args = ap.parse_args()

    if args.stride < 1:
        print("error: --stride must be >= 1", file=sys.stderr)
        return 1

    model = YOLO(args.model)
    if args.half:
        if "cpu" in (args.device or "").lower() or not torch.cuda.is_available():
            print("warning: --half requires a CUDA GPU; ignored", file=sys.stderr)
        else:
            model = model.half()

    source = int(args.source) if args.source.isdigit() else args.source
    is_live = "://" in args.source
    if is_live:
        if args.rtsp_tcp:
            os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp"
        cap = cv2.VideoCapture(source, cv2.CAP_FFMPEG)
    else:
        cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        print(f"error: cannot open source '{args.source}'", file=sys.stderr)
        if is_live:
            print("hint: verify the stream plays in VLC first; for RTSP try --rtsp-tcp", file=sys.stderr)
        return 1

    fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)) or 0
    min_size_px = args.min_size * min(width, height)

    if args.tracker is None and args.stride > 1:
        args.tracker = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cfg", "bytetrack_strong.yaml")
        print(f"[auto] using {os.path.basename(args.tracker)} (--stride > 1 keeps track IDs stable)")

    appear_min = max(1, round((args.appear_seconds if args.appear_seconds is not None else 0.25) * fps))
    merge_frames = max(1, round((args.merge_seconds if args.merge_seconds is not None else 0.8) * fps))
    merge_gap = args.merge_gap if args.merge_gap is not None else 0.10
    gap_width_samples: list[float] = []
    auto_gap_done = args.merge_gap is not None or args.mode != "appear"
    auto_info_printed = False

    writer = None
    if "://" in args.source:
        host = urlparse(args.source).hostname or "camera"
        base = host.replace(".", "_")
    else:
        base = os.path.splitext(args.source)[0]
    if args.save:
        writer = cv2.VideoWriter(f"{base}_counted.mp4", cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height))

    snap_dir = None
    snap_saved: set[int] = set()
    if not args.no_snapshots:
        snap_dir = base
        os.makedirs(snap_dir, exist_ok=True)

    def fmt_time(seconds: float) -> str:
        m, s = divmod(int(seconds), 60)
        return f"{m:02d}:{s:02d}"

    def save_snap(num: int, box: tuple[float, float, float, float]) -> None:
        if snap_dir is None or num in snap_saved:
            return
        snap_saved.add(num)
        x1, y1, x2, y2 = box
        pad = max(4, int(min(x2 - x1, y2 - y1) * 0.05))
        sx1, sy1 = max(0, int(x1) - pad), max(0, int(y1) - pad)
        sx2, sy2 = min(width, int(x2) + pad), min(height, int(y2) + pad)
        crop = frame[sy1:sy2, sx1:sx2]
        if crop.size:
            cv2.putText(crop, str(num), (4, 16), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
            st = fmt_time(frames_done / fps).replace(":", "_")
            name = f"{num}_{st}.jpg"
            i = 1
            while os.path.exists(os.path.join(snap_dir, name)):
                name = f"{num}_{st}_{i}.jpg"
                i += 1
            cv2.imwrite(os.path.join(snap_dir, name), crop)

    prev_pos: dict[int, float] = {}
    seen_frames: dict[int, int] = {}
    last_seen: dict[int, tuple[int, float, float]] = {}
    last_seen_h: dict[int, float] = {}
    last_edge: dict[int, bool] = {}
    num_by_id: dict[int, int] = {}
    num_owner: dict[int, int] = {}
    counted_ids: set[int] = set()
    dir_counts = {"in": 0, "out": 0}
    next_num = 1
    axis = args.line_axis
    line_pos = int((height if axis == "horizontal" else width) * max(0.0, min(1.0, args.line)))

    if args.in_direction is not None:
        if axis == "horizontal" and args.in_direction in ("left-to-right", "right-to-left"):
            print("error: --in-direction left/right requires --line-axis vertical", file=sys.stderr)
            return 1
        if axis == "vertical" and args.in_direction in ("top-to-bottom", "bottom-to-top"):
            print("error: --in-direction top/bottom requires --line-axis horizontal", file=sys.stderr)
            return 1
    in_inc = {"top-to-bottom": True, "bottom-to-top": False,
              "left-to-right": True, "right-to-left": False}[
        args.in_direction or ("top-to-bottom" if axis == "horizontal" else "left-to-right")]
    count_only = args.count if args.count != "both" else None

    def counter_total() -> int:
        if args.mode == "appear":
            return len(set(num_by_id.values())) if num_by_id else 0
        return dir_counts["in"] + dir_counts["out"]

    def write_counter_file() -> None:
        with open(f"{base}_counter.txt", "w", encoding="utf-8") as f:
            if args.mode == "appear":
                f.write(f"people={counter_total()}\n")
                f.write(f"total={counter_total()}\n")
            else:
                f.write(f"in={dir_counts['in']}\n")
                f.write(f"out={dir_counts['out']}\n")
                f.write(f"total={counter_total()}\n")

    frames_done = 0
    read_failures = 0
    if args.show:
        cv2.namedWindow("people counter", cv2.WINDOW_NORMAL)
        try:
            import ctypes
            user32 = ctypes.windll.user32
            scr_w, scr_h = user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)
        except Exception:
            scr_w, scr_h = 1366, 768
        scale = min(1.0, (scr_w - 80) / max(width, 1), (scr_h - 120) / max(height, 1))
        cv2.resizeWindow("people counter", max(320, int(width * scale)), max(240, int(height * scale)))
    while True:
        ok = True
        for _ in range(args.stride):
            if not cap.grab():
                ok = False
                break
        if ok:
            ok, frame = cap.retrieve()
        if not ok:
            if is_live:
                read_failures += 1
                if read_failures > 20:
                    print(f"error: source '{args.source}' stopped delivering frames", file=sys.stderr)
                    break
                cv2.waitKey(250)
                continue
            break
        read_failures = 0
        if args.max_frames and frames_done >= args.max_frames:
            break
        frames_done += args.stride

        factor = 1.0
        if args.show:
            _rx, _ry, disp_w, _disp_h = cv2.getWindowImageRect("people counter")
            if disp_w > 0:
                factor = max(1.0, min(6.0, width / disp_w))
        label_scale = 0.6 * factor
        counter_scale = 1.0 * factor
        thick = max(1, round(2 * factor))

        track_kwargs = dict(classes=[0], conf=args.conf, imgsz=args.imgsz, verbose=False)
        if args.tracker:
            track_kwargs["tracker"] = args.tracker
        if args.device:
            track_kwargs["device"] = args.device
        results = model.track(frame, persist=True, **track_kwargs)
        boxes = results[0].boxes
        if boxes is not None and boxes.id is not None:
            xyxy = boxes.xyxy.cpu().numpy()
            ids = [int(t) for t in boxes.id.int().tolist()]
            skip = set()
            if min_size_px > 0:
                skip = {t for b, t in zip(xyxy, ids)
                        if min(b[2] - b[0], b[3] - b[1]) < min_size_px}
            cur_ids = {t for t in ids if t not in skip}
            live_pos = {
                t: ((b[0] + b[2]) / 2, (b[1] + b[3]) / 2)
                for b, t in zip(xyxy, ids) if t not in skip
            }
            frame_boxes = {}
            for box, tid in zip(xyxy, ids):
                if tid in skip:
                    continue
                x1, y1, x2, y2 = map(float, box)
                frame_boxes[tid] = (x1, y1, x2, y2)
                cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
                if not auto_gap_done:
                    gap_width_samples.append(x2 - x1)

                if args.mode == "appear":
                    seen_frames[tid] = seen_frames.get(tid, 0) + args.stride
                    if tid not in counted_ids and seen_frames[tid] >= appear_min:
                        num = num_by_id.get(tid)
                        if num is None:
                            best, best_d2 = None, float("inf")
                            max_gap = merge_gap * width
                            h = y2 - y1
                            for other, (fidx, ox, oy) in last_seen.items():
                                if other not in counted_ids or other in cur_ids:
                                    continue
                                absent = frames_done - fidx
                                if absent < 3 or absent > merge_frames:
                                    continue
                                dx, dy = cx - ox, cy - oy
                                if dx * dx + dy * dy > max_gap * max_gap:
                                    continue
                                oh = last_seen_h.get(other, 0.0)
                                if oh <= 0 or not (0.6 <= h / oh <= 1.7):
                                    continue
                                if any((ox - px) ** 2 + (oy - py) ** 2 <= max_gap ** 2
                                       for t2, (px, py) in live_pos.items() if t2 != tid):
                                    continue
                                if last_edge.get(other):
                                    continue
                                d2 = dx * dx + dy * dy
                                if d2 < best_d2:
                                    best_d2, best = d2, other
                            if best is not None and any(
                                    num_by_id.get(t2) == num_by_id[best] for t2 in cur_ids if t2 != tid):
                                best = None
                            if best is not None:
                                num = num_by_id[best]
                        if num is None:
                            num = next_num
                            next_num += 1
                        num_by_id[tid] = num
                        counted_ids.add(tid)
                        if num not in num_owner:
                            num_owner[num] = tid
                        save_snap(num, (x1, y1, x2, y2))
                    last_seen[tid] = (frames_done, cx, cy)
                    last_seen_h[tid] = y2 - y1
                    if tid in counted_ids:
                        edge = max(3, int(0.02 * min(width, height)))
                        last_edge[tid] = (x1 <= edge or y1 <= edge or x2 >= width - edge or y2 >= height - edge)
                else:
                    coord = cy if axis == "horizontal" else cx
                    prev = prev_pos.get(tid)
                    if prev is not None and tid not in counted_ids:
                        if in_inc:
                            if prev < line_pos <= coord:
                                direction = "in"
                            elif prev > line_pos >= coord:
                                direction = "out"
                            else:
                                direction = None
                        else:
                            if prev > line_pos >= coord:
                                direction = "in"
                            elif prev < line_pos <= coord:
                                direction = "out"
                            else:
                                direction = None
                        if direction and count_only is not None and direction != count_only:
                            direction = None
                        if direction:
                            dir_counts[direction] += 1
                            num_by_id[tid] = next_num
                            num_owner[next_num] = tid
                            next_num += 1
                            counted_ids.add(tid)
                            save_snap(next_num - 1, (x1, y1, x2, y2))
                    prev_pos[tid] = coord

                num = num_by_id.get(tid)
                label = f"#{num}" if num else f"id:{tid}"
                color = (0, 200, 0) if num else (0, 160, 255)
                cv2.rectangle(frame, (int(x1), int(y1)), (int(x2), int(y2)), color, thick)
                cv2.putText(frame, label, (int(x1), int(y1) - 8),
                            cv2.FONT_HERSHEY_SIMPLEX, label_scale, color, thick)

            if args.mode == "appear":
                claimed: dict[int, int] = {}
                for tid in cur_ids:
                    n = num_by_id.get(tid)
                    if n is None:
                        continue
                    if n not in claimed:
                        claimed[n] = tid
                        continue
                    owner = num_owner.get(n)
                    if tid == owner:
                        imposter = claimed[n]
                        claimed[n] = tid
                    else:
                        imposter = tid
                    new_num = next_num
                    next_num += 1
                    num_by_id[imposter] = new_num
                    num_owner[new_num] = imposter
                    claimed[new_num] = imposter
                    box = frame_boxes.get(imposter)
                    if box is not None:
                        save_snap(new_num, box)
                        ix1, iy1, ix2, iy2 = map(int, box)
                        cv2.rectangle(frame, (ix1, iy1), (ix2, iy2), (0, 200, 0), thick)
                        cv2.putText(frame, f"#{new_num}", (ix1, iy1 - 8),
                                    cv2.FONT_HERSHEY_SIMPLEX, label_scale, (0, 200, 0), thick)

        if args.mode == "appear" and len(last_seen) > 600:
            cutoff = frames_done - (merge_frames + 30)
            last_seen = {k: v for k, v in last_seen.items() if v[0] >= cutoff}
            last_seen_h = {k: v for k, v in last_seen_h.items() if k in last_seen}
            last_edge = {k: v for k, v in last_edge.items() if k in last_seen}

        if not auto_gap_done and (frames_done >= 90 or len(gap_width_samples) >= 30):
            gap_width_samples.sort()
            median_w = gap_width_samples[len(gap_width_samples) // 2] if gap_width_samples else 0.0
            if median_w > 0:
                merge_gap = max(0.03, min(0.07, median_w / width))
            else:
                merge_gap = 0.05
            auto_gap_done = True
        if not auto_info_printed and auto_gap_done and args.mode == "appear":
            auto_info_printed = True
            auto_parts = []
            if args.merge_seconds is None:
                auto_parts.append(f"merge_frames={merge_frames}")
            if args.appear_seconds is None:
                auto_parts.append(f"appear_min={appear_min}")
            if args.merge_gap is None:
                auto_parts.append(f"gap={merge_gap:.2f}")
            if auto_parts:
                print("[auto] " + " ".join(auto_parts))

        if args.mode == "line":
            if axis == "horizontal":
                cv2.line(frame, (0, line_pos), (width, line_pos), (0, 0, 255), 2)
            else:
                cv2.line(frame, (line_pos, 0), (line_pos, height), (0, 0, 255), 2)
        counter_text = (
            f"People: {counter_total()}"
            if args.mode == "appear"
            else f"In: {dir_counts['in']}  Out: {dir_counts['out']}  Total: {counter_total()}"
        )
        (_tw, th), _bl = cv2.getTextSize(counter_text, cv2.FONT_HERSHEY_SIMPLEX, counter_scale, thick)
        cv2.putText(frame, counter_text, (10, th + thick),
                    cv2.FONT_HERSHEY_SIMPLEX, counter_scale, (0, 255, 255), thick)

        bar_h = max(3, round(4 * factor))
        bar_y = height - int(16 * factor)
        elapsed = frames_done / fps
        if total_frames:
            frac = min(1.0, frames_done / total_frames)
            cv2.rectangle(frame, (10, bar_y), (width - 10, bar_y + bar_h), (60, 60, 60), -1)
            cv2.rectangle(frame, (10, bar_y),
                          (10 + int((width - 20) * frac), bar_y + bar_h), (0, 200, 255), -1)
            time_text = f"{fmt_time(elapsed)} / {fmt_time(total_frames / fps)}"
        else:
            time_text = f"{fmt_time(elapsed)}"
        cv2.putText(frame, time_text, (10, bar_y - max(4, round(3 * factor))),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5 * factor, (255, 255, 255), max(1, round(thick * 0.5)))

        write_counter_file()

        if writer is not None:
            writer.write(frame)
        if args.show:
            cv2.imshow("people counter", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

    cap.release()
    if writer is not None:
        writer.release()
    cv2.destroyAllWindows()

    if args.mode == "appear":
        print(f"people={counter_total()}")
    else:
        print(f"in={dir_counts['in']} out={dir_counts['out']} total={counter_total()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())