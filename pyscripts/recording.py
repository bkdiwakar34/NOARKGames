"""
Validation recording: the tracker's full per-frame output to disk, plus the
OptiTrack sync pin. Used by main.py when Godot's installer screen asks for a
recording ("REC_START:<name>" / "REC_STOP"). See docs/validation_plan.md.

Nothing here runs during a normal patient session: main.py only creates a
Recording when Godot asks for one. The sync watcher does run always — it only
waits on a pin — so the gate's state can be shown before recording starts.
"""

import csv
import json
import os
import queue
import re
import shutil
import subprocess
import threading
import time
from datetime import datetime

import numpy as np
from scipy.spatial.transform import Rotation

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_DIR = os.path.dirname(_SCRIPT_DIR)

SAMPLE_COLUMNS = [
    "sample",
    "t_cam0_s", "t_cam1_s",               # capture time, monotonic clock (same as sync.csv)
    "seq_cam0", "seq_cam1",               # kernel frame sequence numbers
    "fusion",                             # cam0 / cam1 / both / cam0_disagree / cam1_disagree / (blank)
    "n_markers_cam0", "n_markers_cam1",
    "reproj_cam0_px", "reproj_cam1_px",
    "stereo_gap_mm", "stereo_gap_deg",    # cam0 vs cam1 pose, when both solved
    "tx_m", "ty_m", "tz_m",               # board pose, cam0 frame
    "qx", "qy", "qz", "qw",
    "game_x_m", "game_y_m", "game_z_m",   # grip point, game (origin-lock) frame
]
CORNER_COLUMNS = ["sample", "cam", "marker_id",
                  "u0", "v0", "u1", "v1", "u2", "v2", "u3", "v3"]

_NAME_OK = re.compile(r"[^A-Za-z0-9_.-]")


def sanitize_name(name: str) -> str:
    """Folder-safe recording name — Godot builds it from dropdowns, but the
    tracker must never turn a stray character into a path."""
    return _NAME_OK.sub("_", name.strip())[:120]


def _fmt(value, spec: str) -> str:
    return "" if value is None else format(value, spec)


def _git_state() -> dict:
    def run(*args):
        try:
            return subprocess.run(["git", *args], cwd=_REPO_DIR, capture_output=True,
                                  text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return ""
    return {"commit": run("rev-parse", "HEAD"),
            "uncommitted_changes": bool(run("status", "--porcelain"))}


class SyncWatcher:
    """Waits for edges on the OptiTrack sync pin in a background thread and
    passes each one on as (kernel time in monotonic seconds, rising?) — the
    same clock the camera frames are stamped with. The internal pull-down
    keeps an unplugged pin LOW instead of floating."""

    def __init__(self, chip: str, line: int, on_edge) -> None:
        import gpiod
        from gpiod.line import Bias, Clock, Edge, Value

        self._line = line
        self._on_edge = on_edge
        self._active = Value.ACTIVE
        self.bias = "pull-down"
        settings = gpiod.LineSettings(edge_detection=Edge.BOTH, bias=Bias.PULL_DOWN,
                                      event_clock=Clock.MONOTONIC)
        try:
            self._req = gpiod.request_lines(chip, consumer="noark-tracker",
                                            config={line: settings})
        except OSError:
            settings.bias = Bias.AS_IS
            self.bias = "none (pull-down refused)"
            self._req = gpiod.request_lines(chip, consumer="noark-tracker",
                                            config={line: settings})
        self.high = self._req.get_value(line) == self._active
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        import gpiod
        rising_type = gpiod.EdgeEvent.Type.RISING_EDGE
        while not self._stop.is_set():
            if not self._req.wait_edge_events(0.1):
                continue
            for ev in self._req.read_edge_events():
                rising = ev.event_type == rising_type
                self.high = rising
                self._on_edge(ev.timestamp_ns / 1e9, rising)

    def close(self) -> None:
        self._stop.set()
        self._thread.join(timeout=1.0)
        self._req.release()


class Recording:
    """The files of one recording.

    Rows are written as they come, but forced to disk only every
    FLUSH_PERIOD_S: flushing all three files 100 times a second cost about 3
    dropped camera frames per 40 s (2026-09-21 T0 run). A crash then loses at
    most that half-second of a validation recording — the patient game's own
    CSVs still flush per row, where losing rows would matter."""

    FLUSH_PERIOD_S = 0.5

    def __init__(self, folder: str, name: str, settings: dict, extra_meta: dict) -> None:
        os.makedirs(folder)                      # refuses an existing name
        self.folder = folder
        self.name = name
        self.n_samples = 0                       # queued by the tracker loop
        self.n_marks = 0
        self.dropped_rows = 0                    # queue full — writer fell behind
        self.rising = []
        self.falling = []
        self.missed_frames = 0                   # gaps in cam0's sequence numbers
        self._rows_written = 0                   # written by the writer thread
        self._last_seq0 = None
        self._t_first = None
        self._t_last = None
        self._last_flush = time.monotonic()

        copied, missing = self._copy_calibration(settings)
        meta = {
            "name": name,
            "created": datetime.now().isoformat(timespec="seconds"),
            "git": _git_state(),
            "calibration_copied": copied,
            "calibration_missing": missing,
            "settings": settings,
            "clock": ("t_cam0_s, t_cam1_s and sync.csv t_s are CLOCK_MONOTONIC "
                      "seconds; Unix time = monotonic + mono_to_unix_s"),
            "units": {
                "t_*_s": "s (monotonic)",
                "tx_m, ty_m, tz_m, qx..qw": "board pose (board = reference marker frame) "
                                            "in cam0's camera frame; quaternion x, y, z, w",
                "game_*_m": "grip point in the game (origin-lock) frame; blank "
                            "until the origin is locked",
                "reproj_*_px": "board-solve reprojection error, kept even when "
                               "the solve was rejected (> stereo_max_reproj_px)",
                "stereo_gap_*": "cam0 pose vs cam1 pose moved into cam0's frame",
                "corners.csv u, v": "px in the undistorted image (pinhole, "
                                    "intrinsics = undistorted.camera_matrix_cam0/1 "
                                    "below — the calibrated matrix with its centre "
                                    "moved by the border — zero distortion); ArUco "
                                    "corner order TL, TR, BR, BL",
            },
            **extra_meta,
        }
        with open(os.path.join(folder, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)

        self._samples_f = open(os.path.join(folder, "samples.csv"), "w", newline="")
        self._corners_f = open(os.path.join(folder, "corners.csv"), "w", newline="")
        self._sync_f    = open(os.path.join(folder, "sync.csv"), "w", newline="")
        self._marks_f   = open(os.path.join(folder, "marks.csv"), "w", newline="")
        self._samples = csv.writer(self._samples_f)
        self._corners = csv.writer(self._corners_f)
        self._sync    = csv.writer(self._sync_f)
        self._marks   = csv.writer(self._marks_f)
        self._samples.writerow(SAMPLE_COLUMNS)
        self._corners.writerow(CORNER_COLUMNS)
        self._sync.writerow(["t_s", "edge"])
        self._marks.writerow(["t_s", "sample", "label"])
        for f in (self._samples_f, self._corners_f, self._sync_f, self._marks_f):
            f.flush()

        # 400 frames of slack (4 s): a burst of slow writes delays rows rather
        # than losing them, and a queue that fills anyway is counted, not hidden.
        self._queue = queue.Queue(maxsize=400)
        self._writer = threading.Thread(target=self._writer_loop, daemon=True)
        self._writer.start()

    def _copy_calibration(self, settings: dict):
        names = [
            settings.get("calibration_file", "camera_calib.toml"),
            settings.get("camera_calib_file_1", "camera_calib_1.toml"),
            settings.get("stereo_extrinsics_file", "stereo_extrinsics.json"),
            settings.get("board_geometry_file", "board_geometry.json"),
            "origin_lock.json",
        ]
        calib_dir = os.path.join(self.folder, "calib")
        os.makedirs(calib_dir)
        copied, missing = [], []
        for name in names:
            path = name if os.path.isabs(name) else os.path.join(_SCRIPT_DIR, name)
            if os.path.exists(path):
                shutil.copy2(path, calib_dir)
                copied.append(os.path.basename(path))
            else:
                missing.append(name)
        return copied, missing

    def write_sample(self, r) -> None:
        """Hand one FrameResult (main.py) to the writer thread.

        The tracker loop has ~10 ms per frame and was already using 9.95 of
        it, so formatting and writing ten CSV rows must not happen here: this
        only queues the result (microseconds) and the writer thread does the
        work between frames."""
        self.n_samples += 1
        try:
            self._queue.put_nowait(r)
        except queue.Full:
            self.dropped_rows += 1

    def _writer_loop(self) -> None:
        while True:
            item = self._queue.get()
            if item is None:
                return
            try:
                self._write_sample_now(item)
            except Exception as exc:                  # never kill the thread
                print(f"[warn] recording writer: {exc}")

    def _write_sample_now(self, r) -> None:
        """One FrameResult -> one samples.csv row + one corners.csv row per
        marker each camera saw. Runs on the writer thread."""
        n = self._rows_written
        self._rows_written += 1
        if r.seq[0] is not None:
            if self._last_seq0 is not None and r.seq[0] > self._last_seq0 + 1:
                self.missed_frames += r.seq[0] - self._last_seq0 - 1
            self._last_seq0 = r.seq[0]
        t = r.t_cap[0] if r.t_cap[0] is not None else r.t_cap[1]
        if t is not None:
            self._t_first = t if self._t_first is None else self._t_first
            self._t_last = t

        n_markers = [0 if ids is None else len(ids) for ids in r.ids]
        gap_mm = gap_deg = None
        if r.stereo_gap is not None:
            gap_mm, gap_deg = r.stereo_gap[0] * 1000.0, float(np.degrees(r.stereo_gap[1]))
        pose = [None] * 7
        if r.fused is not None:
            rvec = np.asarray(r.fused[0], dtype=np.float64).reshape(3)
            tvec = np.asarray(r.fused[1], dtype=np.float64).reshape(3)
            pose = [*tvec, *Rotation.from_rotvec(rvec).as_quat()]
        game = ([None] * 3 if r.local_coords is None
                else list(np.asarray(r.local_coords).reshape(3)))

        self._samples.writerow(
            [n,
             _fmt(r.t_cap[0], ".6f"), _fmt(r.t_cap[1], ".6f"),
             _fmt(r.seq[0], "d"), _fmt(r.seq[1], "d"),
             r.fusion or "",
             n_markers[0], n_markers[1],
             _fmt(r.reproj[0], ".4f"), _fmt(r.reproj[1], ".4f"),
             _fmt(gap_mm, ".3f"), _fmt(gap_deg, ".3f")]
            + [_fmt(v, ".6f") for v in pose[:3]]
            + [_fmt(v, ".8f") for v in pose[3:]]
            + [_fmt(v, ".6f") for v in game]
        )
        for cam in (0, 1):
            corners, ids = r.corners[cam], r.ids[cam]
            if ids is None:
                continue
            for c, marker_id in zip(corners, np.asarray(ids).flatten()):
                uv = np.asarray(c, dtype=np.float64).reshape(8)
                self._corners.writerow([n, cam, int(marker_id)] + [f"{x:.4f}" for x in uv])
        now = time.monotonic()
        if now - self._last_flush >= self.FLUSH_PERIOD_S:
            self._last_flush = now
            self._samples_f.flush()
            self._corners_f.flush()

    def write_edge(self, t: float, rising: bool) -> None:
        # Flushed at once, unlike the sample rows: there are only two of these
        # per recording and the whole alignment depends on them.
        (self.rising if rising else self.falling).append(t)
        self._sync.writerow([f"{t:.6f}", "rising" if rising else "falling"])
        self._sync_f.flush()

    def write_mark(self, t: float, label: str) -> None:
        """One labelled moment from Godot's recorder screen — the start and end
        of each T1 hold, each T3 target reached. `sample` is the row in
        samples.csv written most recently, so a hold is the rows between its
        two marks. Flushed at once: there are only a few hundred per recording
        and the analysis depends on them."""
        self.n_marks += 1
        self._marks.writerow([f"{t:.6f}", self.n_samples, label])
        self._marks_f.flush()

    @property
    def duration_s(self) -> float:
        if self._t_first is None:
            return 0.0
        return self._t_last - self._t_first

    def summary(self) -> str:
        """One line for the installer screen: what was saved, and whether the
        sync looks right (exactly one rising edge, then one falling)."""
        ok = (len(self.rising) == 1 and len(self.falling) == 1
              and self.rising[0] < self.falling[0])
        line = (f"{self.name}: {self.n_samples} samples, {self.duration_s:.1f} s, "
                f"{self.missed_frames} missed frames, {self.n_marks} marks, "
                f"{len(self.rising)} rising + {len(self.falling)} falling edges")
        if self.dropped_rows:
            line += f", {self.dropped_rows} ROWS DROPPED (writer fell behind)"
        if ok:
            return line + f" — OK (Motive take {self.falling[0] - self.rising[0]:.3f} s)"
        return line + " — CHECK SYNC (expected 1 rising then 1 falling)"

    def close(self) -> None:
        # Let the writer finish what is queued before the files are closed.
        self._queue.put(None)
        self._writer.join(timeout=10.0)
        for f in (self._samples_f, self._corners_f, self._sync_f, self._marks_f):
            f.close()
