# The Rigid-Body Tracking Math — Old vs New

> **Scope.** This document is the *argument*: why the joint solve beats per-marker
> averaging, derived from constraint counts and failure modes. For the full pipeline
> in execution order (camera model → distortion → detection → refinement → pose →
> origin lock → filters) see [tracker-math.md](tracker-math.md). Measured outcome:
> median device wobble 3.27 mm → 0.78 mm across 43 workspace positions
> (`tools/analyze_jitter.py`).

*Written 2026-07-07. Companion to the code in `pyscripts/board.py`, `pyscripts/calibrate_board.py`, and `pyscripts/main.py`. Math renders in Obsidian's preview mode.*

This note explains, from the ground up, what the old per-marker tracking algorithm did, what the new rigid-body (joint) algorithm does, and mathematically why the new one has far less depth (Z) jitter.

---

## 1. Coordinate frames and rigid transforms

A **coordinate frame** is a choice of origin plus three perpendicular axes. The system uses:

| Frame | Origin | Axes |
|---|---|---|
| **Camera** | at the lens | Z points out into the scene, X right, Y down |
| **Marker $i$** (one per marker) | marker's center | X/Y in the marker plane, Z out of the printed face |
| **Board** (= device) | defined as marker 12's frame | same as marker 12 |
| **World** (locked at session start) | grip position at origin-lock | board axes at origin-lock |

A **rigid transform** converts a point's coordinates from one frame to another:

$$p_{cam} = R \, p_{marker} + t$$

- $R$ is a $3 \times 3$ **rotation matrix**. Its columns are the marker's X, Y, Z axes *written in camera coordinates*. Because the columns are unit-length and mutually perpendicular ($R^T R = I$), the inverse is simply the transpose: $R^{-1} = R^T$.
- $t$ is the position of the marker's origin in camera coordinates.

The pair $(R, t)$ **is** the pose: 6 degrees of freedom (3 position + 3 rotation).

Two operations used everywhere:

**Inversion** (go the other way):
$$p_{marker} = R^T (p_{cam} - t)$$

**Composition** (chain two frames): if $p_{board} = R_1 p_{marker} + t_1$ and $p_{cam} = R_2 p_{board} + t_2$, substituting gives
$$p_{cam} = (R_2 R_1)\, p_{marker} + (R_2 t_1 + t_2)$$

so chained transforms collapse into one: rotation $R_2 R_1$, translation $R_2 t_1 + t_2$.

> **Code note:** OpenCV stores rotations compactly as a 3-vector `rvec` (rotation axis × rotation angle). `cv2.Rodrigues(rvec)` converts to/from the $3\times3$ matrix. Same information, different packaging.

---

## 2. How a 3D point becomes a pixel (the camera model)

After the fisheye undistortion step (`cv2.remap` in `main.py`), the image behaves like an ideal **pinhole camera**. A 3D point in camera coordinates $p_{cam} = (X, Y, Z)$ lands on the sensor at pixel

$$u = f_x \frac{X}{Z} + c_x, \qquad v = f_y \frac{Y}{Z} + c_y$$

where $f_x, f_y$ (focal lengths in pixels) and $c_x, c_y$ (optical center) come from `camera_calib.toml` — together the **intrinsic matrix** $K$.

The one property that drives this whole story: **the division by $Z$**. Position on the sensor tells you the *direction* to a point very precisely, but says nothing directly about distance. Distance must be inferred from how the *shape* of a known object is squashed by that division — and that inference is where all the jitter comes from.

---

## 3. The PnP problem

**Perspective-n-Point (PnP):** given
- $n$ 3D points with known coordinates in some object frame: $X_1 \dots X_n$,
- their detected pixel positions $u_1 \dots u_n$,
- the camera intrinsics $K$,

find the object pose $(R, t)$ that best explains the pixels:

$$\min_{R,\,t} \; \sum_{k=1}^{n} \big\| \,\mathrm{project}\!\left(K,\; R X_k + t\right) - u_k \,\big\|^2$$

The quantity being minimized is the **reprojection error** — how far, in pixels, the predicted corner positions land from the detected ones. `cv2.solvePnP` solves this. Everything below is just two different choices of *what the object is*.

---

## 4. The OLD algorithm: five independent solves

For each detected marker $i$, the object was **one 50 mm square** — 4 corners in the marker's own frame:

$$X_k \in \left\{ (\pm \tfrac{L}{2}, \pm \tfrac{L}{2}, 0) \right\}, \quad L = 0.05\,\text{m}$$

**Step 1.** Solve PnP once per marker, using only that marker's 4 pixels → poses $(R_4, t_4), (R_8, t_8), \dots$ Each solve has 6 unknowns constrained by 8 measurements (4 corners × 2 pixel coordinates).

**Step 2.** Each marker votes for the grip point using its stored offset (grip position in that marker's frame, `MARKER_OFFSETS`):

$$g_i = R_i \, o_i + t_i$$

**Step 3.** Weighted average of the votes (weight = marker's projected pixel area):

$$g = \frac{\sum_i w_i \, g_i}{\sum_i w_i}$$

### Why this jitters in Z — three compounding problems

**(a) Depth is read from apparent size alone.**
For a small square at distance $Z$ with side $s$ pixels on screen, $s \approx f L / Z$, so

$$\frac{\Delta Z}{Z} \approx \frac{\Delta s}{s}$$

Corner detection noise is ~0.1 px. On a ~90 px marker that is ~0.1% size noise → ~0.1% depth noise → **≈ 0.5–1 mm of Z jitter per frame at 50 cm, minimum**, growing quadratically with distance ($\Delta Z \propto Z^2 / (fL)$). Meanwhile lateral (X, Y) error from the same 0.1 px is only ~0.05 mm — this asymmetry is why the jitter lives specifically in Z.

**(b) The two-tilt ambiguity (the sudden jumps).**
A *planar* square seen near-frontally admits **two** poses — tilted one way or mirrored the other way — whose projections differ by less than the corner noise. Formally, the perspective foreshortening term that distinguishes them is second-order in the tilt angle, so for small tilts the two minima of the reprojection error are nearly equal. `SOLVEPNP_IPPE_SQUARE` computes both and picks the lower-error one; pixel noise makes that choice flip between frames. Each flip drags the depth and rotation estimates with it → discrete Z jumps.

**(c) Lever-arm amplification.**
Step 2 multiplies rotation error by the offset length. With $\|o_i\| \approx$ 5–12 cm, a rotation error of $\theta$ radians displaces the grip vote by $\approx \theta \, \|o_i\|$: just 2° ≈ 0.035 rad on marker 20's 12.5 cm arm is **≈ 4 mm** of grip error. And rotation is precisely the noisiest part of a single-marker solve (problem b).

**(d) Why averaging can't rescue it.**
Averaging $m$ noisy votes reduces *independent* noise only by $\sqrt{m}$, and the votes are partly correlated (same lighting, same viewing geometry). Worse: the *relative spread between markers* — the strongest depth cue in the image — was discarded in Step 1, because each solve saw only its own marker. Information thrown away before averaging cannot be averaged back.

---

## 5. The NEW algorithm: one rigid body, one solve

**Insight:** the markers are glued to one rigid object. Their poses relative to each other are physical constants. So measure those constants **once** (calibration), then treat the whole device as a single object with ~20 known 3D points.

### 5.1 The stored geometry

Calibration (`calibrate_board.py`, §6) produces, for each marker $i$, its fixed pose **in the board frame**: $(R^{b}_{i}, t^{b}_{i})$ such that

$$p_{board} = R^{b}_{i} \, p_{marker_i} + t^{b}_{i}$$

From this, every corner's position in the board frame is a known constant:

$$X^{board}_{i,k} = R^{b}_{i} X_k + t^{b}_{i}$$

Stored in `board_geometry.json`, along with one consensus **grip point** $g_{board}$ (a fixed point in the board frame).

### 5.2 The runtime solve

Whatever subset $V$ of markers is visible this frame, stack all their corners into one PnP problem with a **single** unknown pose:

$$\min_{R,\,t} \; \sum_{i \in V} \sum_{k=1}^{4} \big\| \,\mathrm{project}\!\left(K,\; R\, X^{board}_{i,k} + t\right) - u_{i,k} \,\big\|^2$$

Then the grip point in camera coordinates — no voting, no averaging:

$$g = R \, g_{board} + t$$

### 5.3 The mathematical contrast, side by side

With 3 markers visible:

| | Old | New |
|---|---|---|
| Unknowns | $6 \times 3 = 18$ | $6$ |
| Measurements | $8$ per solve | $24$ into one solve |
| Constraint ratio | $8/6 \approx 1.3$ | $24/6 = 4$ |
| 3D points per solve | 4, **coplanar** | 12+, **non-coplanar** |
| Depth read from | one marker's ~90 px size | whole device's ~250 px spread |
| Grip point | lever-arm votes, averaged | one fixed point, transformed |

### 5.4 Why each failure mode dies

**(a) Depth:** precision scales with the pixel span of the measured shape. The device spans ~250 px vs a single marker's ~90 px → ~3× better depth sensitivity, on top of the $\sqrt{3}$ from extra corners. Expected Z noise drops from ~1 mm to **~0.2–0.3 mm** from the same pixels.

**(b) Ambiguity:** the two-tilt ambiguity is a property of **coplanar** point sets. Your facets are angled (60°, 10°), so the stacked 3D points are non-coplanar — the mirrored pose now projects visibly wrongly, the second minimum disappears, and the solution is **unique**. No more flips whenever ≥ 2 non-parallel markers are visible.

**(c) Lever arm:** there is no per-marker rotation to propagate. $g_{board}$ rides directly on the single, well-constrained body pose.

**(d) Nothing discarded:** the cross-marker spread enters the optimization directly, because all corners are in one cost function.

**Graceful degradation:** with only 1 marker visible the math necessarily reduces to the old single-marker quality (the solver falls back to IPPE + composition, or refines from the previous frame's pose). That is why adding side markers to the reprint helps: it makes "≥ 2 visible" true from every therapy pose.

---

## 6. Where the geometry constants come from (calibration math)

`calibrate_board.py` never measures a marker's pose on the device directly — it measures **relative poses** between markers seen in the same frame, then chains them.

**Per frame:** for every pair $(i, j)$ visible together, solve each marker's individual PnP (old-style), giving $(R_i, t_i)$ and $(R_j, t_j)$ in camera coordinates. The **relative transform** (marker $j$'s frame expressed in marker $i$'s frame) is, by composition + inversion:

$$R_{ij} = R_i^T R_j, \qquad t_{ij} = R_i^T (t_j - t_i)$$

Key point: $(R_{ij}, t_{ij})$ is a **physical constant** — however the device is held, however the camera sits. Each frame gives one noisy sample of it. Frames where the single-marker solve is unreliable are rejected first: reprojection error > 1 px, or the two IPPE solutions too close (ambiguity ratio < 2) — the flip problem from §4b would otherwise poison the samples.

**Averaging hundreds of samples:**
- Translations: trimmed mean (outliers beyond 5 mm of the median discarded).
- Rotations: matrices can't be averaged naively (the mean of two rotation matrices is generally not a rotation matrix). The **chordal mean** is used: average the matrices entry-wise, then project back onto the set of valid rotations via SVD — if $\bar{M} = U \Sigma V^T$, the nearest rotation is $\bar{R} = U V^T$ (with a sign fix if $\det < 0$). Samples more than 3° from the mean are trimmed, then re-averaged.

Residual scatter shrinks like $1/\sqrt{N}$, so ~100 samples per pair beat any single-frame measurement by an order of magnitude.

**Chaining to the board frame:** marker 12 is declared the board frame: $(R^b_{12}, t^b_{12}) = (I, 0)$. Any marker with an averaged pair-path to 12 gets its board pose by composition, e.g. via marker 4:

$$R^b_{20} = R_{12,4}\, R_{4,20}, \qquad t^b_{20} = R_{12,4}\, t_{4,20} + t_{12,4}$$

(BFS over the pair graph — markers never seen with 12 directly still get linked through intermediates. This is why the back marker calibrates through side views.)

**Grip-point consensus:** each marker independently predicts the grip in board coordinates, $g^{(i)} = R^b_i \, o_i + t^b_i$. If geometry and offsets are right, all predictions agree; their mean becomes $g_{board}$ and their spread (printed at the end of calibration) is a built-in sanity check. Your run: 0.8–5.8 mm, marker 20 worst — consistent with its long lever arm amplifying a small CAD/gluing angle error.

---

## 7. From body pose to game coordinates (origin lock)

At session start, once detections are stable for 10 frames, the current pose is **locked** as the world reference: store $R_0$ (board orientation) and $g_0$ (grip position in camera coordinates at lock time). Every subsequent frame reports the grip's displacement *in the locked board axes*:

$$p_{local} = R_0^T (g_0 - g)$$

This is what streams over UDP to Godot. Note it only involves the *one* body pose — under the old algorithm the same formula hung off a single designated marker's noisy pose, adding its jitter to every coordinate.

---

## 8. Summary table

| Failure mode | Cause (old) | Cure (new) |
|---|---|---|
| Continuous Z shimmer | depth from one marker's apparent size (~90 px) | depth from device-wide spread (~250 px) + 3× corners |
| Sudden Z jumps | two-tilt ambiguity of a lone coplanar square | non-coplanar point set → unique pose |
| mm-level grip wobble | rotation noise × 5–12 cm lever arms, then averaged | grip is a fixed point on one well-constrained body |
| Jumps when markers appear/disappear | vote set changes → weighted mean shifts | same body pose regardless of which markers feed it |

The remaining weak spot: frames where only **one** marker is visible fall back to old-quality geometry — the motivation for adding side markers in the device reprint.
