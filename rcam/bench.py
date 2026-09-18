"""FPS benchmark for the OV9281 cameras at full resolution (1280x800).

Measures, single-camera and both-in-parallel:
  * ground truth  - `v4l2-ctl` streaming (kernel pipeline, ~no userspace work)
  * rcam raw      - capture_buffer() (read Y10P, no unpack)
  * rcam unpack8  - capture_array() bit_depth=8 (NumPy unpack to uint8)

at the default frame length and at minimum vertical_blanking (max sensor fps).
Frames are read and discarded - nothing is stored.

The unpack8 rows also report frames dropped: produced by the sensor (from the
kernel's sequence numbers) but never read. Each camera's exposure and
vertical_blanking are restored afterwards, so the benchmark leaves the sensors
as it found them.

    sudo modprobe ov9282
    uv run python bench.py
"""
from __future__ import annotations

import re
import subprocess
import threading
import time

from rcam import Camera, list_cameras

DUR = 4.0          # seconds per measurement
WARMUP = 0.5       # seconds discarded before timing


def set_vblank(cam: Camera, vblank: int):
    subprocess.run(["v4l2-ctl", "-d", cam.sensor.subdev,
                    "--set-ctrl", f"vertical_blanking={vblank},exposure=300"],
                   check=True, capture_output=True)


def ground_truth(videos: list[str], seconds: float) -> dict[str, float]:
    """Run a v4l2-ctl stream per video node concurrently; parse reported fps."""
    n = int(seconds * 130) + 30
    procs = {v: subprocess.Popen(
        ["v4l2-ctl", "-d", v, "--stream-mmap", f"--stream-count={n}"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for v in videos}
    out = {v: p.communicate()[0] for v, p in procs.items()}
    fps = {}
    for v, text in out.items():
        vals = [float(m) for m in re.findall(r"([\d.]+) fps", text)]
        fps[v] = max(vals) if vals else float("nan")
    return fps


def read_loop(cam: Camera, unpack: bool, stop: threading.Event, counter: list):
    """counter = [frames read, latest sequence number (None on the raw path)]."""
    while not stop.is_set():
        if unpack:
            _, seq, _ = cam.capture_with_meta()
            counter[1] = seq
        else:
            cam.capture_buffer()
        counter[0] += 1


def bench_python(cams: list[Camera], unpack: bool) -> tuple[list[float], list]:
    """Threaded read from each camera for DUR seconds.

    Returns per-cam fps and per-cam dropped frames. Dropped = frames the sensor
    produced in the window (sequence difference) minus frames read; None on the
    raw path, which carries no sequence number. The two snapshots are not taken
    atomically, so treat +-1 as noise."""
    stop = threading.Event()
    counters = [[0, None] for _ in cams]
    threads = [threading.Thread(target=read_loop, args=(c, unpack, stop, ctr))
               for c, ctr in zip(cams, counters)]
    for c in cams:
        c.flush(4)                       # discard warmup/queue
    for t in threads:
        t.start()
    time.sleep(WARMUP)
    base = [list(c) for c in counters]
    t0 = time.perf_counter()
    time.sleep(DUR)
    dt = time.perf_counter() - t0
    end = [list(c) for c in counters]
    stop.set()
    for t in threads:
        t.join()
    fps = [(e[0] - b[0]) / dt for e, b in zip(end, base)]
    dropped = [None if e[1] is None or b[1] is None else (e[1] - b[1]) - (e[0] - b[0])
               for e, b in zip(end, base)]
    return fps, dropped


def row(label: str, fps: list[float], dropped: list | None = None):
    total = sum(fps)
    per = "  ".join(f"{f:6.1f}" for f in fps)
    line = f"  {label:<22} {per:<18}  total={total:6.1f} fps"
    if dropped and all(d is not None for d in dropped):
        line += "   dropped=" + ", ".join(str(d) for d in dropped)
    print(line)


def save_controls(labels: list[str]) -> dict:
    """Exposure and vertical_blanking per camera, as found before benchmarking."""
    saved = {}
    for label in labels:
        cam = Camera(label)
        saved[label] = (cam.sensor.subdev,
                        cam.get_control("exposure"),
                        cam.get_control("vertical_blanking"))
    return saved


def restore_controls(saved: dict):
    for label, (subdev, exposure, vblank) in saved.items():
        subprocess.run(["v4l2-ctl", "-d", subdev, "--set-ctrl",
                        f"vertical_blanking={vblank},exposure={exposure}"],
                       check=True, capture_output=True)
        print(f"restored {label}: exposure={exposure}, vertical_blanking={vblank}")


def main():
    labels = list_cameras()
    print(f"cameras: {labels}\n")
    if not labels:
        print("none detected - run: sudo modprobe ov9282")
        return

    saved = save_controls(labels)
    try:
        # vblank gates frame length; set it explicitly each pass (sensor controls
        # persist across runs, so we must not rely on "whatever was left").
        for tag, vblank in (("default blanking (vblank=1022)", 1022),
                            ("min blanking (vblank=110, max fps)", 110)):
            print(f"=== {tag} ===")
            # --- ground truth (kernel pipeline) ---
            for scope, sel in (("single (CAM2)", labels[:1]), ("parallel (all)", labels)):
                cams = [Camera(l) for l in sel]
                for c in cams:
                    c._setup_pipeline()
                    subprocess.run(["v4l2-ctl", "-d", c.chain.video, "-v",
                                    "width=1280,height=800,pixelformat=Y10P"],
                                   check=True, capture_output=True)
                    if vblank:
                        set_vblank(c, vblank)
                gt = ground_truth([c.chain.video for c in cams], DUR)
                row(f"ground-truth {scope}", list(gt.values()))

            # --- rcam python path ---
            for unpack, name in ((False, "rcam-raw"), (True, "rcam-unpack8")):
                for scope, sel in (("single", labels[:1]), ("parallel", labels)):
                    cams = [Camera(l).start() for l in sel]
                    if vblank:
                        for c in cams:
                            set_vblank(c, vblank)
                    try:
                        fps, dropped = bench_python(cams, unpack)
                    finally:
                        for c in cams:
                            c.stop()
                    row(f"{name} {scope}", fps, dropped)
            print()
    finally:
        restore_controls(saved)


if __name__ == "__main__":
    main()
