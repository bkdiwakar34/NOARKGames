"""Check that each camera frame arrives with its sequence number and capture time.

    python rcam/check_meta.py

For each camera, grabs a few frames and prints:
    seq    the kernel's frame counter — should rise by 1 per frame
    t_cap  when the frame was captured (seconds, kernel clock)
    delay  now minus t_cap — how long the frame waited before Python got it

delay should be a few milliseconds. A huge value (around 1.7e9 s) means the
kernel stamps frames with wall-clock time rather than the monotonic clock
time.monotonic() uses, and the two cannot be compared directly.
"""
import time

from rcam import Camera, list_cameras

N_FRAMES = 8

for label in list_cameras():
    cam = Camera(label).start()
    try:
        print(f"\n{label}:   seq      t_cap (s)    delay (ms)")
        seqs = []
        for _ in range(N_FRAMES):
            _, seq, t_cap = cam.capture_with_meta()
            delay_ms = (time.monotonic() - t_cap) * 1000.0
            seqs.append(seq)
            print(f"       {seq:6d}   {t_cap:12.4f}   {delay_ms:10.2f}")
    finally:
        cam.stop()

    steps = [b - a for a, b in zip(seqs, seqs[1:])]
    print(f"  seq steps: {steps}   (all 1 = no frames skipped while reading)")
