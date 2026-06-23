# Tracker pipeline — full math walkthrough

End-to-end derivation of how a raw fisheye camera frame becomes a 3D position broadcast to Godot. Walks every stage of `main.py` in execution order, with the equations OpenCV is solving under each function call.

---

## Notation

| Symbol | Meaning |
|---|---|
| $\mathbf{X} = (X, Y, Z)$ | A point in 3D space (in some coordinate frame) |
| $\mathbf{x} = (u, v)$ | A point in 2D image space (pixel coordinates) |
| $\mathbf{K}$ | $3 \times 3$ camera intrinsic matrix |
| $\mathbf{D}$ | Lens distortion coefficients |
| $\mathbf{R}, \mathbf{t}$ | $3 \times 3$ rotation matrix and $3 \times 1$ translation vector |
| $\mathbf{r}$ | Rodrigues vector (3-component representation of $\mathbf{R}$) |
| $f_x, f_y$ | Focal lengths in pixel units |
| $c_x, c_y$ | Principal point (optical centre) in pixels |
| ${}_{\text{cam}}\mathbf{X}$ | Point expressed in the camera frame |
| ${}_{\text{world}}\mathbf{X}$ | Point expressed in the world (locked) frame |
| ${}_{\text{mkr}}\mathbf{X}$ | Point expressed in a marker's local frame |

---

## 0. The pinhole camera model (the reference everything is built on)

The simplest model of how 3D points project to 2D pixels. A 3D point in the **camera frame** at $(X, Y, Z)$, with $Z$ along the camera's optical axis, projects to image coordinates:

$$
u = f_x \cdot \frac{X}{Z} + c_x \qquad v = f_y \cdot \frac{Y}{Z} + c_y
$$

In matrix form, with the projection matrix:

$$
\mathbf{K} = \begin{bmatrix} f_x & 0 & c_x \\ 0 & f_y & c_y \\ 0 & 0 & 1 \end{bmatrix}
$$

we write:

$$
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix} \sim \mathbf{K} \begin{bmatrix} X/Z \\ Y/Z \\ 1 \end{bmatrix}
$$

The four numbers $(f_x, f_y, c_x, c_y)$ are the **intrinsics**. They are properties of the lens + sensor pair, not the scene.

**This model assumes light travels in a straight line from the scene to the sensor through a single optical centre.** Real lenses bend light non-linearly — especially fisheye lenses. That's why we need distortion.

---

## 1. Lens distortion — the fisheye model

The OV9281 has a 160° FOV fisheye lens. Light rays at the edges of the field bend so much that the pinhole model is wrong by tens of pixels. OpenCV provides two distortion families:

| Model | Coefficients | Valid up to | OpenCV |
|---|---|---|---|
| Brown–Conrady (standard) | $(k_1, k_2, p_1, p_2, k_3)$ | ~90° FOV | `cv2.calibrateCamera` |
| Kannala–Brandt (fisheye) | $(k_1, k_2, k_3, k_4)$ | ~180° FOV | `cv2.fisheye.calibrate` |

We use the fisheye model because of the 160° lens.

**The fisheye projection equation** says: given a 3D point in camera frame $(X, Y, Z)$, let

$$
a = X/Z, \quad b = Y/Z, \quad r = \sqrt{a^2 + b^2}, \quad \theta = \arctan(r)
$$

Then a *distorted* angle is computed by applying a 4-coefficient polynomial:

$$
\theta_d = \theta \left(1 + k_1 \theta^2 + k_2 \theta^4 + k_3 \theta^6 + k_4 \theta^8\right)
$$

and the final pixel coordinates are:

$$
x' = \frac{\theta_d}{r} \cdot a, \quad y' = \frac{\theta_d}{r} \cdot b
$$

$$
u = f_x \cdot x' + c_x, \quad v = f_y \cdot y' + c_y
$$

The polynomial in $\theta$ models how aggressively a fisheye lens bends rays as a function of how far they are from the optical axis. With $k_1, k_2, k_3, k_4$ fit from a calibration session, this represents the OV9281's behaviour accurately across the entire 160° field.

**Why the standard pinhole model fails at high FOV:** Brown–Conrady writes distortion as a polynomial in $r$ (radial distance in image space). At fisheye angles, the relationship between $\theta$ (incoming ray angle) and $r$ becomes very non-linear, and a low-order polynomial can't fit both centre and edge accurately at the same time. Kannala–Brandt parametrises directly in $\theta$, which stays well-behaved up to nearly $\pi/2$.

---

## 2. Image undistortion — straightening the fisheye

`main.py` builds an undistortion map once at startup:

```python
self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
    K, D, np.eye(3), K, frame_size, cv2.CV_16SC2
)
```

This precomputes, for every output pixel $(u', v')$ in the corrected (pinhole-equivalent) image, the source coordinate $(u, v)$ in the raw fisheye image:

For each output pixel, the algorithm inverts the fisheye model: from $(u', v')$ recover the normalised ray $(x'/f_x, y'/f_y)$, treat that as a pinhole ray, find the corresponding undistorted angle $\theta$, apply the fisheye polynomial to get $\theta_d$, then compute back where in the raw image to sample.

The output is `map1, map2` — two arrays the size of the output image storing those source coordinates.

At runtime, `cv2.remap(frame, map1, map2, INTER_CUBIC)` samples the raw image at the computed source coordinates for every output pixel. Because source coordinates are usually non-integer, we interpolate:

**Bicubic interpolation** (`INTER_CUBIC`): for an output pixel needing a sample at non-integer $(u, v)$, take a $4 \times 4$ window of integer-pixel values around it and compute a weighted sum:

$$
I(u, v) = \sum_{i=-1}^{2} \sum_{j=-1}^{2} I[u_0 + i, v_0 + j] \cdot W(u - u_0 - i) \cdot W(v - v_0 - j)
$$

where $W(t)$ is a cubic kernel like $W(t) = \frac{3}{2}|t|^3 - \frac{5}{2}|t|^2 + 1$ for $|t| < 1$. The cubic kernel preserves sharp edges much better than bilinear interpolation (`INTER_LINEAR`), which uses only the 4 nearest pixels with linear weights.

**Result:** an image where straight lines in the world are straight in the image. The undistorted image behaves like a pinhole camera with intrinsics $\mathbf{K}$ and *zero* distortion — that's why later `solvePnP` calls pass `np.zeros(5)` for distortion.

---

## 3. Marker detection — pixels to corners

`detectMarkers(undistorted_frame)` runs an 8-stage pipeline internally. Each stage is decision-based, not differentiable math, so the equations here are simpler.

**3.1 Adaptive thresholding.** Convert grayscale to binary. For each pixel $(u, v)$, compute the threshold from the mean of a local $w \times w$ window:

$$
T(u, v) = \frac{1}{w^2} \sum_{i, j \in \text{window}} I(i, j) - C
$$

Pixel is black if $I(u, v) < T(u, v)$, white otherwise. Window sizes $w$ are swept through `adaptiveThreshWinSizeMin..Max` step `adaptiveThreshWinSizeStep`, and detection is attempted at each scale.

**3.2 Contour extraction.** Walks the binary image and traces the boundary between every connected black region and its surrounding white pixels. Each contour is a list of integer-pixel coordinates forming a closed loop.

**3.3 Quad filtering.** Each contour is simplified to a polygon via `approxPolyDP` (Douglas-Peucker). This keeps a contour vertex only if removing it would distort the contour by more than $\epsilon$ pixels, where $\epsilon$ is a fraction of the contour's perimeter:

$$
\epsilon = 0.05 \cdot \text{perimeter}
$$

A candidate is kept only if the simplified polygon has exactly 4 vertices, is convex, and exceeds a minimum area threshold.

**3.4 Perspective rectification.** For each candidate quadrilateral with corners $\{\mathbf{q}_1, \mathbf{q}_2, \mathbf{q}_3, \mathbf{q}_4\}$, compute the homography $\mathbf{H}$ that maps them to a canonical unit square $\{(0,0), (1,0), (1,1), (0,1)\}$:

$$
\begin{bmatrix} sx_i \\ sy_i \\ s \end{bmatrix} = \mathbf{H} \begin{bmatrix} q_{i,x} \\ q_{i,y} \\ 1 \end{bmatrix}
$$

`getPerspectiveTransform` solves the 8-parameter linear system for $\mathbf{H}$. Then `warpPerspective` resamples the marker interior into a $N \times N$ pixel canonical view (typically $N = 64$).

**3.5 Bit decoding.** Divide the canonical view into the dictionary's grid (for `DICT_APRILTAG_36h11`: $8 \times 8$ outer including white border, $6 \times 6$ inner data cells). For each cell, average pixel brightness and threshold → a 36-bit pattern.

**3.6 Dictionary lookup with error correction.** Compute the Hamming distance between the observed 36-bit pattern and every code in the dictionary. AprilTag 36h11 codes are designed so the minimum Hamming distance between any two valid codes is 11. So up to 5 bit errors per marker still uniquely identify it. If the closest match has Hamming distance ≤ 5, the marker's ID is reported.

**3.7 Coarse corner output.** At this point each detected marker has its 4 corners at the integer-pixel positions from Stage 3.

---

## 4. Sub-pixel corner refinement

Stage 3 gives corners with $\pm 1$ pixel accuracy. The refinement step pushes that to $\pm 0.1$–$0.3$ pixels.

**`CORNER_REFINE_CONTOUR`** (our setting):

For each of the 4 sides of the detected marker, collect all the contour pixels along that side from Stage 3. Fit a line to those pixels by least squares:

For a side with $N$ contour pixels $\{(x_k, y_k)\}_{k=1..N}$, find $(a, b, c)$ minimising

$$
\sum_{k} (a x_k + b y_k + c)^2 \quad \text{subject to} \quad a^2 + b^2 = 1
$$

This is a total least-squares line fit. Equivalently, find the smallest eigenvector of the covariance matrix of the centred points.

A corner is then the intersection of two adjacent fitted lines. Two lines $\mathbf{L}_1: a_1 x + b_1 y + c_1 = 0$ and $\mathbf{L}_2: a_2 x + b_2 y + c_2 = 0$ intersect at:

$$
x = \frac{b_1 c_2 - b_2 c_1}{a_1 b_2 - a_2 b_1}, \quad y = \frac{a_2 c_1 - a_1 c_2}{a_1 b_2 - a_2 b_1}
$$

The resulting 4 refined corners are accurate to sub-pixel precision because the fitted lines average over many pixels of contour.

---

## 5. Pose estimation — solving for marker pose from 4 corners

`cv2.solvePnP(obj_points, img_points, K, np.zeros(5), flags=SOLVEPNP_IPPE_SQUARE)`

**The problem:** given the 3D positions of the marker's 4 corners in the *marker's own frame*:

$$
{}_{\text{mkr}}\mathbf{X}_i = \left\{ \begin{pmatrix} -L/2 \\ L/2 \\ 0 \end{pmatrix}, \begin{pmatrix} L/2 \\ L/2 \\ 0 \end{pmatrix}, \begin{pmatrix} L/2 \\ -L/2 \\ 0 \end{pmatrix}, \begin{pmatrix} -L/2 \\ -L/2 \\ 0 \end{pmatrix} \right\}
$$

where $L$ is the physical marker side length (5 cm), and their corresponding pixel positions $\mathbf{x}_i = (u_i, v_i)$ in the (undistorted) image, find a rotation $\mathbf{R}$ and translation $\mathbf{t}$ such that:

$$
\lambda_i \begin{bmatrix} u_i \\ v_i \\ 1 \end{bmatrix} = \mathbf{K} (\mathbf{R} \cdot {}_{\text{mkr}}\mathbf{X}_i + \mathbf{t})
$$

for each corner $i$, for some positive depth $\lambda_i$. This is the **Perspective-n-Point** problem.

**IPPE_SQUARE algorithm** (Infinitesimal Plane-based Pose Estimation for squares): a closed-form solver specifically for planar square targets. Steps:

1. Compute the homography $\mathbf{H}$ between the marker-frame square and the image corners.
2. Decompose $\mathbf{H} = \mathbf{K}[\mathbf{r}_1 | \mathbf{r}_2 | \mathbf{t}]$, where $\mathbf{r}_1, \mathbf{r}_2$ are the first two columns of $\mathbf{R}$ and $\mathbf{t}$ is the translation.
3. Recover $\mathbf{r}_3 = \mathbf{r}_1 \times \mathbf{r}_2$.
4. Because planar pose has a fundamental ambiguity (the marker could be "facing toward" or "facing away" with mirrored rotation), IPPE returns **two valid solutions** with similar reprojection error. Pick the one with the lower error.

Output: $\mathbf{R}$ (rotation matrix, often stored as Rodrigues vector $\mathbf{r}$ where $\mathbf{R} = \exp([\mathbf{r}]_\times)$) and $\mathbf{t}$ (translation in metres) representing the marker's pose in the camera frame.

**Why we pass `np.zeros(5)` for distortion:** the image was already undistorted in Step 2, so it now behaves like a pinhole camera. Telling `solvePnP` "no distortion" is correct because the distortion was already applied upstream.

---

## 6. Centroid from multiple markers

The skateboard has 5 markers (IDs 4, 8, 12, 14, 20) at different positions on different faces. Usually 1–2 are visible per frame. For each visible marker $i$, we have:

- $\mathbf{R}_i, \mathbf{t}_i$ from `solvePnP` — marker $i$'s pose in camera frame.
- `MARKER_OFFSETS[i]` $= {}_{\text{mkr}_i}\mathbf{o}_i$ — vector from marker $i$'s centre to the skateboard's centre, in marker $i$'s own local frame.

**Each marker independently predicts** where the skateboard centre is in the camera frame:

$$
{}_{\text{cam}}\mathbf{c}_i = \mathbf{R}_i \cdot {}_{\text{mkr}_i}\mathbf{o}_i + \mathbf{t}_i
$$

The factor $\mathbf{R}_i$ rotates the offset from marker $i$'s local frame to the camera frame; adding $\mathbf{t}_i$ shifts from marker $i$'s position to the skateboard centre.

**Centroid** = mean of the per-marker predictions:

$$
{}_{\text{cam}}\mathbf{c} = \frac{1}{N} \sum_{i \in \text{visible}} {}_{\text{cam}}\mathbf{c}_i
$$

If all markers are rigidly attached to the same skateboard, all $N$ predictions should agree exactly; in practice they differ slightly due to corner noise, and the mean averages out part of that noise.

---

## 7. World-frame transformation — reporting position relative to a fixed origin

The centroid above is in the **camera frame** — useless to the game, which wants positions relative to the patient's starting pose. So at session start we **lock** the world origin.

**At lock time** (after `ORIGIN_LOCK_FRAMES` of stable detections):

- Save the first detected marker's pose: $\mathbf{R}_0, \mathbf{t}_0$.
- Compute and save the world-origin point in camera frame:

$$
{}_{\text{cam}}\mathbf{c}_0 = \mathbf{R}_0 \cdot {}_{\text{mkr}_0}\mathbf{o}_0 + \mathbf{t}_0
$$

This is the skateboard centre's position in camera frame *at the moment we locked*.

**Every subsequent frame:** compute the displacement of the current centroid from the locked one, in camera frame:

$$
{}_{\text{cam}}\mathbf{d} = {}_{\text{cam}}\mathbf{c}_0 - {}_{\text{cam}}\mathbf{c}
$$

Then rotate that displacement into the world frame (the locked marker's local frame), by multiplying with $\mathbf{R}_0^\top$:

$$
{}_{\text{world}}\mathbf{p} = \mathbf{R}_0^\top \cdot {}_{\text{cam}}\mathbf{d}
$$

This is the reported 3D position: how far and in what direction the skateboard centre has moved since lock time, expressed in axes aligned with the locked marker.

**Caveat:** because $\mathbf{R}_0$ is one marker's local frame (not the rig as a whole), the world axes here depend on which marker happened to be detected first at lock time. A multi-marker `aruco.Board` would replace this with a consistent rig frame derived from CAD.

---

## 8. Smoothing filters — three choices

The world-frame position $\mathbf{p}_t$ above is noisy frame-to-frame. The configurable filter smooths it.

### 8.1 EMA — Exponential Moving Average

A first-order low-pass:

$$
\mathbf{y}_t = \alpha \cdot \mathbf{p}_t + (1 - \alpha) \cdot \mathbf{y}_{t-1}
$$

$\alpha \in (0, 1]$ controls responsiveness:
- $\alpha = 1$: no smoothing, output equals input.
- $\alpha \to 0$: extreme smoothing, output barely moves.

Default: $\alpha = 0.4$. Noise reduction factor at steady state: $\sqrt{\alpha / (2 - \alpha)} \approx 0.5$ (about 2× quieter).

### 8.2 Kalman — constant-velocity model

State vector at time $t$:

$$
\mathbf{s}_t = (x, y, z, v_x, v_y, v_z)^\top
$$

**Predict step:**

$$
\mathbf{s}_t^- = \mathbf{F} \mathbf{s}_{t-1}, \qquad \mathbf{P}_t^- = \mathbf{F} \mathbf{P}_{t-1} \mathbf{F}^\top + \mathbf{Q}
$$

where the constant-velocity transition matrix is

$$
\mathbf{F} = \begin{bmatrix} I_3 & \Delta t \cdot I_3 \\ \mathbf{0}_3 & I_3 \end{bmatrix}
$$

and $\mathbf{Q}$ is the process-noise covariance (how much we expect velocity to change).

**Update step** (given measurement $\mathbf{z}_t = \mathbf{p}_t$ via observation matrix $\mathbf{H} = [I_3 | \mathbf{0}_3]$):

$$
\mathbf{K}_t = \mathbf{P}_t^- \mathbf{H}^\top (\mathbf{H} \mathbf{P}_t^- \mathbf{H}^\top + \mathbf{R})^{-1}
$$
$$
\mathbf{s}_t = \mathbf{s}_t^- + \mathbf{K}_t (\mathbf{z}_t - \mathbf{H} \mathbf{s}_t^-)
$$
$$
\mathbf{P}_t = (\mathbf{I} - \mathbf{K}_t \mathbf{H}) \mathbf{P}_t^-
$$

$\mathbf{R}$ is the measurement-noise covariance (how noisy the input position is).

Output position: the first 3 components of $\mathbf{s}_t$.

**Why this overshoots at stops:** the predict step assumes velocity persists. When the hand stops abruptly, $\mathbf{s}^-$ contains a non-zero velocity for several frames before the update step drives it to zero, producing position values that continue past where the hand actually is.

### 8.3 One Euro filter — speed-adaptive low-pass

Two EMAs stacked: one for velocity estimation, one for position, where the position EMA's $\alpha$ varies with the velocity estimate.

**Compute the noisy raw velocity:**

$$
\dot{\mathbf{p}}_t = \frac{\mathbf{p}_t - \mathbf{p}_{t-1}}{\Delta t}
$$

**Smooth the velocity with a fixed-cutoff EMA:**

$$
\hat{\dot{\mathbf{p}}}_t = \alpha_d \cdot \dot{\mathbf{p}}_t + (1 - \alpha_d) \cdot \hat{\dot{\mathbf{p}}}_{t-1}
$$

where $\alpha_d = \frac{1}{1 + \tau_d / \Delta t}$ and $\tau_d = \frac{1}{2 \pi \cdot f_{d\text{cutoff}}}$.

**Compute the speed magnitude:**

$$
s_t = \|\hat{\dot{\mathbf{p}}}_t\|
$$

**Compute the adaptive cutoff and resulting position $\alpha$:**

$$
f_{\text{cutoff}} = f_{\text{min}} + \beta \cdot s_t
$$
$$
\alpha_p = \frac{1}{1 + \tau_p / \Delta t}, \quad \tau_p = \frac{1}{2 \pi \cdot f_{\text{cutoff}}}
$$

**Smooth the position:**

$$
\mathbf{y}_t = \alpha_p \cdot \mathbf{p}_t + (1 - \alpha_p) \cdot \mathbf{y}_{t-1}
$$

**Why it works for reach-and-hold:** when the hand is still, $s_t \approx 0$ → $f_{\text{cutoff}} = f_{\text{min}}$ → $\alpha_p$ is small → heavy smoothing. When the hand moves, $s_t$ grows → $f_{\text{cutoff}}$ rises → $\alpha_p$ grows → smoothing eases off → no lag.

Parameters:
- $f_{\text{min}}$ (`one_euro_min_cutoff`): cutoff at zero speed. Lower = smoother hold.
- $\beta$ (`one_euro_beta`): how fast the cutoff opens with speed. For input in metres, $\beta \approx 5$–$10$ is reasonable.
- $f_{d\text{cutoff}}$ (`one_euro_d_cutoff`): cutoff for the velocity estimate itself. Higher = the filter reacts faster to stops.

### 8.4 NoOp

Pass-through: $\mathbf{y}_t = \mathbf{p}_t$. Useful for measuring the raw noise floor at the cursor.

---

## 9. UDP packet — sending to Godot

The filtered 3D position is packed into a UDP datagram:

```
[code: f32, x: f32, y: f32, z: f32]   →   16 bytes, little-endian
```

`code` is a command marker (`2.0` = START, `-99.0` = STOP, `5.0` = RESET) used by Godot's state machine.

The packet is sent on the bound socket to whatever address last sent us a message (`self.addr`).

---

## 10. Godot side — world position to screen pixels

`UDPReceiver` (Godot) reads the packet and extracts `raw_x` and `raw_z` (the X and Z components of the world-frame position from Step 7 — the locked marker's local X and Z axes).

If `WorkspaceConfig.sensor_calibrated`, applies the 2D affine transform from the workspace calibration:

$$
\begin{bmatrix} s_x \\ s_y \end{bmatrix} = \begin{bmatrix} a_{00} & a_{01} & a_{02} \\ a_{10} & a_{11} & a_{12} \end{bmatrix} \begin{bmatrix} \text{raw}_x \\ \text{raw}_z \\ 1 \end{bmatrix}
$$

The matrix entries $a_{ij}$ are fit at calibration time by least squares from the 4 corner samples — see `_fit_affine_2d` in `workspace_config.gd`.

This is the cursor position in screen pixels.

---

## Pipeline summary

$$
\text{raw fisheye} \xrightarrow[\text{(K, D, INTER\_CUBIC)}]{\text{cv2.remap}} \text{undistorted}
$$
$$
\xrightarrow[\text{(threshold, contour, quad, decode)}]{\text{detectMarkers}} \{(\text{id}_i, \text{corners}_i)\}_i
$$
$$
\xrightarrow[\text{(line fit, intersection)}]{\text{CORNER\_REFINE\_CONTOUR}} \{\text{refined corners}_i\}
$$
$$
\xrightarrow[\text{(IPPE\_SQUARE)}]{\text{solvePnP}} \{\mathbf{R}_i, \mathbf{t}_i\}_i
$$
$$
\xrightarrow[\text{(per-marker offset, average)}]{\text{\_get\_centroid}} {}_{\text{cam}}\mathbf{c}
$$
$$
\xrightarrow[\text{(locked $\mathbf{R}_0, \mathbf{t}_0$)}]{\text{\_get\_local\_coordinates}} {}_{\text{world}}\mathbf{p}
$$
$$
\xrightarrow[\text{(EMA / Kalman / One Euro / NoOp)}]{\text{filter.update}} \mathbf{y}
$$
$$
\xrightarrow[\text{(struct.pack, sendto)}]{\text{\_send\_coordinates}} \text{UDP packet}
$$
$$
\xrightarrow[\text{(2D affine)}]{\text{Godot WorkspaceConfig.sensor\_to\_screen}} \text{cursor pixels}
$$

Every stage's noise contribution adds (in quadrature) to the final cursor jitter. The diagnostic in `diagnose_jitter.py` measures the noise floors of the first few stages directly.
