"""
Validation recorder: the tracker's full output to disk, next to an OptiTrack
take, synchronised by the eSync 2 "Recording Gate" on a GPIO pin.

See docs/validation_plan.md for what is recorded and why.

Runs the same tracking pipeline as main.py (MainClass, udp=False), so what is
validated is exactly what the game uses. Needs no Godot; cannot run while the
game is running (both open the cameras).

Run on the board, in a terminal on its desktop (it opens a window):

    cd ~/Documents/NOARKGames && source .venv/bin/activate
    python pyscripts/recorder.py

Per recording: pick the name -> Record -> start the Motive take (gate HIGH)
-> do the trial -> stop the Motive take (gate LOW) -> Stop.

One folder per recording, under validation_data_dir (settings.json):
    samples.csv   one row per camera frame pass (100/s)
    corners.csv   one row per marker seen by a camera
    sync.csv      one row per edge on the sync pin
    calib/        copies of the calibration files in use
    meta.json     name, time, settings, git commit, column units
"""

import csv
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import tkinter as tk
from datetime import datetime
from tkinter import messagebox, ttk

import cv2
import numpy as np
from scipy.spatial.transform import Rotation

from main import FrameResult, MainClass, _load_settings, calib_path

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_REPO_DIR = os.path.dirname(_SCRIPT_DIR)

# Trial -> conditions, from docs/validation_plan.md §2. T0 is a dry run for
# checking the setup. T5 (game) is not here: the game and the recorder cannot
# both open the cameras.
TRIALS = {
    "T0": ["test"],
    "T1": ["grid"],
    "T2": [f"{shape}_{speed}" for shape in ("circle", "eight")
           for speed in ("slow", "comfortable", "fast")],
    "T3": ["comfortable", "fast"],
}
REPEATS = [f"r{i}" for i in range(1, 6)]

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


# ── sync pin ─────────────────────────────────────────────────────────────────

class SyncWatcher:
    """Waits for edges on the sync pin in a background thread and passes each
    one on as (kernel time in monotonic seconds, rising?). The internal
    pull-down keeps an unplugged pin LOW instead of floating."""

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
            self._req = gpiod.request_lines(chip, consumer="noark-recorder",
                                            config={line: settings})
        except OSError:
            settings.bias = Bias.AS_IS
            self.bias = "none (pull-down refused)"
            self._req = gpiod.request_lines(chip, consumer="noark-recorder",
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


# ── one recording on disk ────────────────────────────────────────────────────

class Recording:
    """The files of one recording. Every row is flushed to disk as written, so
    a crash or power cut loses at most the row being written."""

    def __init__(self, folder: str, name: str, settings: dict, extra_meta: dict) -> None:
        os.makedirs(folder)                      # refuses an existing name
        self.folder = folder
        self.n_samples = 0
        self.rising = []
        self.falling = []
        self.missed_frames = 0                   # gaps in cam0's sequence numbers
        self._last_seq0 = None
        self._t_first = None
        self._t_last = None

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
                                    "intrinsics = that camera's camera_matrix, "
                                    "zero distortion); ArUco corner order TL, TR, BR, BL",
            },
            **extra_meta,
        }
        with open(os.path.join(folder, "meta.json"), "w") as f:
            json.dump(meta, f, indent=2)

        self._samples_f = open(os.path.join(folder, "samples.csv"), "w", newline="")
        self._corners_f = open(os.path.join(folder, "corners.csv"), "w", newline="")
        self._sync_f    = open(os.path.join(folder, "sync.csv"), "w", newline="")
        self._samples = csv.writer(self._samples_f)
        self._corners = csv.writer(self._corners_f)
        self._sync    = csv.writer(self._sync_f)
        self._samples.writerow(SAMPLE_COLUMNS)
        self._corners.writerow(CORNER_COLUMNS)
        self._sync.writerow(["t_s", "edge"])
        for f in (self._samples_f, self._corners_f, self._sync_f):
            f.flush()

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

    def write_sample(self, r: FrameResult) -> None:
        n = self.n_samples
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
        game = [None] * 3 if r.local_coords is None else list(np.asarray(r.local_coords).reshape(3))

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
        self._samples_f.flush()
        self._corners_f.flush()
        self.n_samples += 1

    def write_edge(self, t: float, rising: bool) -> None:
        (self.rising if rising else self.falling).append(t)
        self._sync.writerow([f"{t:.6f}", "rising" if rising else "falling"])
        self._sync_f.flush()

    @property
    def duration_s(self) -> float:
        if self._t_first is None:
            return 0.0
        return self._t_last - self._t_first

    def close(self) -> None:
        for f in (self._samples_f, self._corners_f, self._sync_f):
            f.close()


# ── the app ──────────────────────────────────────────────────────────────────

class RecorderApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.settings = _load_settings()
        # The preview window would need cv2.imshow from the tracker thread,
        # and turns off the search box; the recorder shows its own status.
        self.settings["debug_preview"] = False
        self.data_dir = os.path.expanduser(
            self.settings.get("validation_data_dir", "~/Documents/NOARK/validation"))

        self._lock = threading.Lock()
        self.recording = None
        self._last = None                        # latest FrameResult, for the display
        self._pass_count = 0
        self._rate = 0.0
        self._rate_t = time.monotonic()
        self._rate_n = 0
        self._tracker_error = None

        print("Starting cameras and tracker...")
        self.tracker = MainClass(cam_calib_path=calib_path(self.settings),
                                 settings=self.settings, udp=False)

        self.sync = None
        self.sync_error = None
        chip = self.settings.get("sync_gpio_chip", "/dev/gpiochip4")
        line = int(self.settings.get("sync_gpio_line", 1))
        try:
            self.sync = SyncWatcher(chip, line, self._on_edge)
        except Exception as exc:                 # no gpiod, no permission, line busy
            self.sync_error = f"{type(exc).__name__}: {exc}"
            print(f"[warn] sync pin {chip} line {line} unavailable: {self.sync_error}")
        self.sync_desc = {"chip": chip, "line": line,
                          "bias": self.sync.bias if self.sync else None}

        self._build_ui()
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._tracker_loop, daemon=True)
        self._thread.start()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
        self.root.after(200, self._refresh)

    # ── UI ──

    def _build_ui(self) -> None:
        self.root.title("NOARK validation recorder")
        pad = {"padx": 6, "pady": 4}
        big = ("TkDefaultFont", 14)

        row = ttk.Frame(self.root)
        row.pack(fill="x", **pad)
        self.date = datetime.now().strftime("%Y-%m-%d")
        ttk.Label(row, text=f"Name:  {self.date}").pack(side="left")
        self.trial = ttk.Combobox(row, values=list(TRIALS), state="readonly", width=5)
        self.trial.current(0)
        self.trial.pack(side="left", padx=4)
        self.cond = ttk.Combobox(row, state="readonly", width=20)
        self.cond.pack(side="left", padx=4)
        self.rep = ttk.Combobox(row, values=REPEATS, state="readonly", width=4)
        self.rep.current(0)
        self.rep.pack(side="left", padx=4)
        self.trial.bind("<<ComboboxSelected>>", lambda _e: self._on_trial())
        self.cond.bind("<<ComboboxSelected>>", lambda _e: self._update_name())
        self.rep.bind("<<ComboboxSelected>>", lambda _e: self._update_name())

        self.name_label = ttk.Label(self.root, font=big)
        self.name_label.pack(anchor="w", **pad)

        buttons = ttk.Frame(self.root)
        buttons.pack(fill="x", **pad)
        self.rec_btn = ttk.Button(buttons, text="Record", command=self._start)
        self.rec_btn.pack(side="left")
        self.stop_btn = ttk.Button(buttons, text="Stop", command=self._stop_recording,
                                   state="disabled")
        self.stop_btn.pack(side="left", padx=6)

        self.status = ttk.Label(self.root)
        self.status.pack(anchor="w", **pad)
        self.gate = ttk.Label(self.root, font=big)
        self.gate.pack(anchor="w", **pad)
        self.device = ttk.Label(self.root, font=big)
        self.device.pack(anchor="w", **pad)
        self.saved = ttk.Label(self.root)
        self.saved.pack(anchor="w", **pad)

        self._on_trial()

    def _on_trial(self) -> None:
        self.cond["values"] = TRIALS[self.trial.get()]
        self.cond.current(0)
        self._update_name()

    def _name(self) -> str:
        return f"{self.date}_{self.trial.get()}_{self.cond.get()}_{self.rep.get()}"

    def _update_name(self) -> None:
        self.name_label["text"] = self._name()

    # ── threads ──

    def _tracker_loop(self) -> None:
        while not self._stop.is_set():
            try:
                r = self.tracker.process_frame()
            except Exception as exc:
                self._tracker_error = f"{type(exc).__name__}: {exc}"
                print(f"[error] tracker stopped: {self._tracker_error}")
                return
            if r is None:
                continue
            with self._lock:
                self._last = r
                self._pass_count += 1
                if self.recording is not None:
                    self.recording.write_sample(r)

    def _on_edge(self, t: float, rising: bool) -> None:
        with self._lock:
            if self.recording is not None:
                self.recording.write_edge(t, rising)

    # ── record / stop ──

    def _start(self) -> None:
        name = self._name()
        folder = os.path.join(self.data_dir, name)
        if os.path.exists(folder):
            messagebox.showerror("Name in use",
                                 f"{folder}\nalready exists. Pick the next repeat.")
            return
        if self.sync is None and not messagebox.askyesno(
                "No sync pin",
                f"The sync pin is unavailable ({self.sync_error}).\n"
                "This recording cannot be aligned with Motive. Record anyway?"):
            return
        extra = {"trial": self.trial.get(), "condition": self.cond.get(),
                 "repeat": self.rep.get(), "sync_pin": self.sync_desc,
                 "mono_to_unix_s": time.time() - time.monotonic()}
        try:
            rec = Recording(folder, name, self.settings, extra)
        except OSError as exc:
            messagebox.showerror("Cannot create recording", str(exc))
            return
        with self._lock:
            self.recording = rec
        self.rec_btn["state"] = "disabled"
        self.stop_btn["state"] = "normal"
        for box in (self.trial, self.cond, self.rep):
            box["state"] = "disabled"

    def _stop_recording(self) -> None:
        with self._lock:
            rec, self.recording = self.recording, None
        if rec is None:
            return
        rec.close()
        self.rec_btn["state"] = "normal"
        self.stop_btn["state"] = "disabled"
        for box in (self.trial, self.cond, self.rep):
            box["state"] = "readonly"

        summary = (f"{rec.n_samples} samples over {rec.duration_s:.1f} s, "
                   f"{rec.missed_frames} missed camera frames.\n"
                   f"Sync edges: {len(rec.rising)} rising, {len(rec.falling)} falling.")
        ok_sync = (len(rec.rising) == 1 and len(rec.falling) == 1
                   and rec.rising[0] < rec.falling[0])
        if ok_sync:
            gate_s = rec.falling[0] - rec.rising[0]
            messagebox.showinfo("Saved", f"{rec.folder}\n\n{summary}\n"
                                         f"Motive take on the Dragon's clock: {gate_s:.3f} s.")
        else:
            messagebox.showwarning(
                "Saved — check the sync",
                f"{rec.folder}\n\n{summary}\n\nExpected exactly 1 rising then 1 "
                "falling edge: start Motive after Record, stop it before Stop.")
        # Next repeat ready, so the same name is not reused by accident.
        i = REPEATS.index(self.rep.get())
        if i + 1 < len(REPEATS):
            self.rep.current(i + 1)
        self._update_name()

    # ── display ──

    def _refresh(self) -> None:
        with self._lock:
            r = self._last
            n = self._pass_count
            rec = self.recording
            n_saved = rec.n_samples if rec else 0
            edges = (len(rec.rising), len(rec.falling)) if rec else None

        now = time.monotonic()
        if now - self._rate_t >= 1.0:
            self._rate = (n - self._rate_n) / (now - self._rate_t)
            self._rate_t, self._rate_n = now, n

        if self._tracker_error:
            self.status["text"] = f"TRACKER STOPPED: {self._tracker_error}"
        else:
            n0 = n1 = 0
            if r is not None:
                n0 = 0 if r.ids[0] is None else len(r.ids[0])
                n1 = 0 if r.ids[1] is None else len(r.ids[1])
            fusion = (r.fusion if r is not None and r.fusion else "no pose")
            self.status["text"] = (f"{self._rate:5.1f} samples/s   |   cam0: {n0} markers   "
                                   f"cam1: {n1} markers   |   pose from: {fusion}")

        if self.sync is None:
            self.gate["text"] = f"Sync pin: UNAVAILABLE ({self.sync_error})"
        else:
            level = "HIGH (Motive recording)" if self.sync.high else "LOW"
            count = "" if edges is None else f"   edges this recording: {edges[0]} rising, {edges[1]} falling"
            self.gate["text"] = f"Gate: {level}{count}"

        self.device["text"] = self._device_text(r)
        self.saved["text"] = (f"Recording: {n_saved} samples -> {rec.folder}" if rec
                              else f"Not recording.   Data folder: {self.data_dir}")
        self.root.after(200, self._refresh)

    def _device_text(self, r) -> str:
        """Placement guidance: position on the table and heading, relative to
        the locked origin (the parking pose)."""
        origin_R = self.tracker._origin_R
        if r is None or r.fused is None:
            return "Device: not seen"
        if origin_R is None or r.local_coords is None:
            return "Device: seen, origin not locked yet (hold still)"
        # local_coords = R_lock^T (grip_lock - grip), so the displacement from
        # the origin is its negative. Board +Y is device-up (board.py), so the
        # table plane is x-z and yaw is the turn about Y.
        d = -np.asarray(r.local_coords).reshape(3) * 1000.0
        R = cv2.Rodrigues(np.asarray(r.fused[0], dtype=np.float64).reshape(3))[0]
        yaw = Rotation.from_matrix(origin_R.T @ R).as_euler("YXZ", degrees=True)[0]
        return (f"Device:  x = {d[0]:7.1f} mm   z = {d[2]:7.1f} mm   "
                f"yaw = {yaw:6.1f}°      (height {d[1]:5.1f} mm)")

    # ── shutdown ──

    def _on_close(self) -> None:
        if self.recording is not None and not messagebox.askyesno(
                "Recording", "A recording is running. Stop it and quit?"):
            return
        self._stop_recording()
        self._stop.set()
        self._thread.join(timeout=2.0)
        if self.sync is not None:
            self.sync.close()
        self.tracker.close()
        self.root.destroy()


def main() -> None:
    root = tk.Tk()
    try:
        RecorderApp(root)
    except Exception as exc:
        root.destroy()
        sys.exit(f"Could not start the recorder: {exc}")
    root.mainloop()


if __name__ == "__main__":
    main()
