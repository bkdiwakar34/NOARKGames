

End-to-end derivation of how a raw fisheye camera frame becomes a 3D position broadcast to Godot. Walks every stage of `main.py` in execution order, with the equations OpenCV is solving under each function call.

> **Scope.** This is the pipeline reference — every stage, in order, as deployed
> (§6 and §7 updated 2026-07-28 for the joint rigid-body solve and the validated,
> persistent origin lock). For the focused *why the new method beats the old* argument
> — constraint counts, failure modes, the depth-precision derivation — see
> [rigid_body_math.md](rigid_body_math.md). For the measured result, see
> `tools/analyze_jitter.py` and its figures.

---

## The story in one page

Everything below is one long inversion. The camera destroys information — it flattens a 3D
world onto a 2D grid of brightness values — and the tracker's job is to recover the part
that was lost. It cannot do that directly, so the strategy throughout is: **build an
accurate forward model of how the camera turns 3D into pixels, then search for the 3D pose
whose predicted pixels match what was actually seen.**

**None of it runs until the camera's own constants are known.** The forward model has
parameters — $f_x, f_y, c_x, c_y$ and the distortion coefficients — and they are properties
of one physical camera unit, not values anyone can look up. So there is a prerequisite step,
performed **once, offline**, before any tracking happens:

| Prerequisite | Produces | Covered in |
|---|---|---|
| Camera calibration (`calibrate_camera.py`) | $f_x, f_y, c_x, c_y$ and $k_1 \ldots k_4$ → `camera_calib.toml` | §0.7, §1 |
| Board calibration (`calibrate_board.py`) | where each marker sits on the device → `board_geometry.json` | §6.3 |

Both invert the same logic as tracking, but with the unknowns swapped: photograph something
whose 3D geometry is *known* (a chessboard of measured squares; markers on a rigid device),
and solve for the constants instead of the pose. Get these wrong and every stage below
inherits the error silently — the pipeline will still run and still produce plausible
numbers.

With those in hand, the per-frame pipeline follows the arc above:

| § | Stage | What it contributes |
|---|---|---|
| 0 | Pinhole model | The forward model in its simplest form: 3D point → pixel, via four constants. Exact near the image centre. |
| 1 | Lens distortion | Our 160° lens does not obey the simple model at the edges. Measure how it actually behaves. |
| 2 | Undistortion | Undo that deviation once per frame, so every later stage can use §0's simple equations and ignore the lens. |
| 3 | Marker detection | Find the black-and-white squares in the image and read their IDs — the raw evidence. |
| 4 | Corner refinement | Locate each corner to sub-pixel precision. Everything downstream inherits this accuracy. |
| 5 | Pose estimation | **The inversion.** Search for the pose whose projected corners best match the detected ones. |
| 6 | Combining markers | Fuse all visible markers into one device pose, using the calibrated board geometry. |
| 7 | World frame | Re-express that pose relative to a fixed, locked origin, so numbers mean the same thing across sessions. |
| 8 | Filtering | Smooth the frame-to-frame result before it drives the game. |

Two threads run through all of it. **Accuracy compounds**: a fraction of a pixel of corner
error in §4 becomes millimetres of position error by §7. And **each stage exists to let the
next one stay simple** — undistortion is done so pose estimation can pretend the lens is
perfect; board calibration is done so pose estimation can treat many markers as one object.

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

## 0. The pinhole camera model — how a 3D point becomes a pixel

This is the foundation for everything that follows. Goal: derive *exactly* how a 3D point in space ends up at a specific pixel $(u, v)$ on the camera sensor. The equation $u = f_x \cdot X/Z + c_x$ shows up over and over later — here's where it comes from and what each piece means.

**Why build the forward model when tracking needs the reverse?** Tracking asks the
opposite question: given detected marker corners, where is the marker in 3D? There is no
direct formula for that — a single pixel could have come from a near point or a far one,
so depth is genuinely ambiguous. What the tracker does instead is *search*: guess a pose,
project it forward with the equations below, compare against the pixels actually detected,
and adjust. The forward model is the thing being run inside that loop, thousands of times
a second. Get it right and everything downstream follows; get it wrong and every pose is
wrong in the same way. The search itself is §5.

The chain in this section runs: coordinate frame → the projection itself → converting to
pixels → shifting the origin to the image corner → the same thing in matrix notation →
where the four constants come from → what the model assumes, and why a 160° lens breaks
those assumptions (leading into §1).

### 0.1 The camera frame

First we need a coordinate system to describe 3D positions. The **camera frame** is the natural one:

- The **origin** sits at the camera's optical centre — conceptually a single point inside the lens.
- The **Z-axis** points *forward*, straight out of the lens, along the direction the camera is facing.
- The **X-axis** points *right* (when looking at the camera from behind).
- The **Y-axis** points *down* (OpenCV convention — opposite of a typical maths textbook).

So a point at $(X, Y, Z) = (0, 0, 1)$ is exactly 1 metre directly in front of the camera, on the optical axis. $(0.1, 0, 1)$ is 1 metre in front and 10 cm to the right. $(0, 0, 2)$ is 2 metres directly in front.

```
                    ↑ -Y (up)
                    |        / Z (forward, into scene)
                    |      /
      camera  ●─────────────→ +X (right)
                    |
                    ↓ +Y (down)
```

### 0.2 The pinhole intuition

Imagine the lens is reduced to a single tiny hole. Light from every 3D point in the scene travels in a straight line through that hole and lands on the image sensor sitting some distance $f$ (the **focal length**) behind it.

For a 3D point at $(X, Y, Z)$ in camera frame, draw a straight line from it through the origin. Extend the line past the origin until it hits the sensor plane. By **similar triangles** (the big triangle from the 3D point to the origin, and the small triangle from the origin to the sensor), the image of $\mathbf{X}$ lands at:

$$
x_{\text{sensor}} = f \cdot \frac{X}{Z}, \qquad y_{\text{sensor}} = f \cdot \frac{Y}{Z}
$$

That's the core of the entire projection. Read it as: **"take the X coordinate, scale by focal length, divide by depth."** Two important consequences fall out:

1. **Depth shrinks things.** Doubling $Z$ halves $x_{\text{sensor}}$ — that's why distant objects appear smaller on the sensor.
2. **The relationship is linear in X and Y at a fixed depth.** A 1 cm shift in $X$ produces a fixed $f/Z$ pixel shift in the image — predictable and well-behaved.

### 0.3 From sensor millimetres to pixels

First, what the two words mean:

- **The sensor** is the whole light-sensitive chip — one piece of silicon carrying a grid
  of $1280 \times 800$ pixels. On the OV9281 each pixel is $3\,\mu\text{m}$ square, so the
  chip measures about $3.84 \times 2.40$ mm in total.
- **$x_{\text{sensor}}$** is *where on that chip the light landed*, measured as a physical
  distance from the chip's centre. The previous section gave it in metres.

The image we actually get is not a physical distance, though — it is a grid of pixel
counts. So we need to convert. Call the width of one pixel $s$ (metres **per pixel**;
$s = 3\times10^{-6}$ m here). Then:

$$
\underbrace{u_{\text{from-centre}}}_{\text{pixels}}
\;=\;
\frac{\overbrace{x_{\text{sensor}}}^{\text{metres}}}{\underbrace{s}_{\text{metres/pixel}}}
$$

**Concretely:** light landing 1 mm right of the chip's centre is
$0.001 / (3\times10^{-6}) \approx 333$ pixels right of centre.

Substituting $x_{\text{sensor}} = f \cdot X/Z$ from §0.2:

$$
u_{\text{from-centre}} = \frac{f}{s} \cdot \frac{X}{Z}
$$

The combined quantity $f/s$ is metres ÷ (metres/pixel) = **pixels**. This is the
**focal length in pixels**, written $f_x$ — and it is the number that appears in your
calibration file:

$$
f_x = \frac{f}{s_x}, \qquad f_y = \frac{f}{s_y}
$$

Two things worth being clear about, because the textbook version of this derivation is
misleading in practice:

**We never compute $f_x$ this way.** Calibration estimates $f_x$ and $f_y$ *directly*, in
pixels, by fitting to chessboard images. The physical focal length $f$ and pixel pitch $s$
are never measured separately, and never needed at runtime. The derivation above explains
what $f_x$ *means*; it is not the procedure that produces it.

**$f_x \neq f_y$ here is not caused by rectangular pixels.** Textbooks introduce two focal
lengths to allow for non-square pixels, but the OV9281's pixels *are* square. Your
calibration reports $f_x = 887.3$ and $f_y = 890.0$ — a 0.3 % difference that is estimation
noise from the fit, not a property of the sensor. Treat a large gap between the two as a
sign of a poor calibration, not of exotic hardware.

### 0.4 Shifting from sensor-centre to image-corner

Pixel coordinates in an image are usually measured from a corner of the image (typically top-left), not from the centre of the sensor. So we add a constant offset:

$$
u = f_x \cdot \frac{X}{Z} + c_x, \qquad v = f_y \cdot \frac{Y}{Z} + c_y
$$

$(c_x, c_y)$ is the **principal point** — the pixel position where the optical axis (the Z-axis itself, i.e. the direction the camera is facing) hits the sensor. For an ideal camera with the sensor perfectly centred on the lens axis, $c_x \approx \text{image\_width} / 2$ and $c_y \approx \text{image\_height} / 2$. In practice, manufacturing tolerances shift it by a few pixels.

### 0.5 Worked numerical example

Suppose your camera has:
- $f_x = 800$ pixels, $f_y = 800$ pixels
- $c_x = 640$, $c_y = 400$ (perfectly centred on a 1280×800 image)

**Question 1.** Where does a point at $(X, Y, Z) = (0.0, 0.0, 0.5)$ land?

$$
u = 800 \cdot \frac{0.0}{0.5} + 640 = 0 + 640 = 640
$$
$$
v = 800 \cdot \frac{0.0}{0.5} + 400 = 0 + 400 = 400
$$

Dead centre of the image. Makes sense — the 3D point is on the optical axis at 0.5 m depth.

**Question 2.** Where does $(0.05, 0.0, 0.5)$ land? (5 cm to the right of the optical axis, 0.5 m depth.)

$$
u = 800 \cdot \frac{0.05}{0.5} + 640 = 800 \cdot 0.1 + 640 = 80 + 640 = 720
$$
$$
v = 800 \cdot \frac{0.0}{0.5} + 400 = 400
$$

80 pixels right of centre. The Y projection is still 0 because the 3D point has $Y = 0$.

**Question 3.** Now move the same lateral point further away — $(0.05, 0.0, 1.0)$. Where?

$$
u = 800 \cdot \frac{0.05}{1.0} + 640 = 40 + 640 = 680
$$

Only 40 pixels right of centre. Twice as far away → half as offset on the sensor. That's the perspective effect captured cleanly.

### 0.6 Matrix form

Everything so far is two scalar equations:

$$
u = f_x \cdot \frac{X}{Z} + c_x, \qquad v = f_y \cdot \frac{Y}{Z} + c_y
$$

This section repackages them as one matrix multiplication. **No new mathematics happens
here** — it is the same two equations. The point is that the packaged form composes with
the other transforms in the pipeline (§5, §7) and is what OpenCV expects as an argument.

**The intrinsic matrix** collects the four camera constants:

$$
\mathbf{K} = \begin{bmatrix} f_x & 0 & c_x \\ 0 & f_y & c_y \\ 0 & 0 & 1 \end{bmatrix}
$$

Note what this separates: $\mathbf{K}$ is entirely *the camera* — it does not change when
the scene moves. The point being photographed is the other operand.

**Why the extra 1.** Multiply $\mathbf{K}$ by the ratios $(X/Z,\; Y/Z)$ with a 1 appended,
and expand it row by row:

$$
\mathbf{K}\begin{bmatrix} X/Z \\ Y/Z \\ 1 \end{bmatrix}
=
\begin{bmatrix}
f_x \cdot \tfrac{X}{Z} + 0 \cdot \tfrac{Y}{Z} + c_x \cdot 1 \\[2pt]
0 \cdot \tfrac{X}{Z} + f_y \cdot \tfrac{Y}{Z} + c_y \cdot 1 \\[2pt]
1
\end{bmatrix}
=
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
$$

The first two rows are exactly the scalar equations. And notice what the appended 1 is
doing: it multiplies the third column, which is how $c_x$ and $c_y$ get **added**.

That is the whole trick of **homogeneous coordinates**. A plain $2 \times 2$ matrix can
only scale and rotate — it can never add a constant offset, because every term is
multiplied by an input that could be zero. Appending a coordinate fixed at 1 gives the
matrix a term that is always present, so a shift becomes expressible as multiplication.
Once shifts are multiplications, whole chains of operations collapse into one matrix
product.

**Why the $\sim$.** The same projection is more often written with the raw 3D point,
un-divided:

$$
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix} \sim \mathbf{K} \begin{bmatrix} X \\ Y \\ Z \end{bmatrix}
= \begin{bmatrix} f_x X + c_x Z \\ f_y Y + c_y Z \\ Z \end{bmatrix}
$$

This is *not* the pixel coordinate yet — every entry is $Z$ times too large. Divide
through by the third component:

$$
\begin{bmatrix} f_x X/Z + c_x \\ f_y Y/Z + c_y \\ 1 \end{bmatrix}
$$

and the correct answer appears. The $\sim$ means "equal up to a positive scale factor,"
i.e. *divide by the last component to get the real pixel*.

This is worth pausing on: **that final division is the perspective effect itself.** The
matrix multiplication is entirely linear — it cannot shrink distant objects. All the
depth-dependence of §0.2 lives in that one normalising division, which is why the model
is called *projective* rather than linear, and why $Z$ is the awkward unknown when the
problem is inverted (§5).

In code, either form works — dividing first, or dividing after:

```python
# ratios first (division done by hand)
projected = K @ np.array([X / Z, Y / Z, 1.0])
u, v = projected[0], projected[1]

# raw point, then homogeneous normalisation
projected = K @ np.array([X, Y, Z])
u, v = projected[0] / projected[2], projected[1] / projected[2]
```

### 0.7 The intrinsics, and where the four numbers come from

The complete forward model needs exactly four constants: $(f_x, f_y, c_x, c_y)$. Together
they are called the **intrinsics** — properties of *this* lens-and-sensor pair, fixed for
the life of the camera and independent of the scene in front of it.

They are not looked up in a datasheet; they are **measured**, once per camera unit, by
`calibrate_camera.py`. The procedure inverts the logic of everything above: photograph a
chessboard whose square size is known, so the true 3D geometry is not in doubt, then find
the intrinsics that make the projected corners land closest to the corners actually
detected. Roughly:

$$
(f_x, f_y, c_x, c_y, \mathbf{D}) \;=\; \arg\min \sum_{\text{all corners}} \left\| \text{detected} - \text{projected} \right\|^2
$$

The residual of that fit is the **reprojection error** reported at the end of calibration —
0.63 px for our camera. It is the single best summary of calibration quality: under ~1 px
is good, and a much larger value means the intrinsics are not describing this camera well,
so every pose computed later inherits the error.

That same fit also produces the distortion coefficients $\mathbf{D}$, which is what the
next section is about.

### 0.8 What the model assumes — and why a 160° lens breaks it

The model above assumes:

- Light travels in **straight lines** from each 3D point through a single optical centre.
- The sensor is **flat** and perpendicular to the optical axis.

A real lens bends light, and the further off-axis the ray arrives, the more the landing
position departs from what the pinhole equations predict. The pinhole model says a ray
arriving at angle $\theta$ from the optical axis lands at radius $r = f\tan\theta$ from the
image centre (since $X/Z = \tan\theta$); a fisheye lands it at roughly $r = f\theta$.
With our $f_x = 887$ px:

| Ray angle off-axis | Pinhole predicts | Fisheye actually |
|---|---|---|
| 10° | 156 px | 155 px |
| 30° | 512 px | 465 px |
| 60° | 1536 px | 929 px |
| 80° | **5030 px** | 1238 px |

Near the centre the two agree almost exactly — which is why the pinhole model survives as
the backbone of the maths. Toward the edges they diverge badly.

The last row also shows why a 160° lens *has* to work this way: $\tan\theta \to \infty$ as
$\theta \to 90°$, so a rectilinear lens physically cannot capture that field of view — the
light would need to land far off the chip. A fisheye deliberately compresses wide angles to
fit them on the sensor.

The next section models that compression, so the pinhole equations can still be used
downstream.

---

## 1. Lens distortion — the fisheye model

§0.8 introduced a second rung: the pinhole model puts a ray at $r = f\tan\theta$, while a
fisheye puts it at roughly $r = f\theta$. That word **roughly** is what this section is
about. $r = f\theta$ describes an *ideal* fisheye; no physical lens follows it exactly.
So there are three rungs, each closer to the truth:

| | Landing radius | Describes |
|---|---|---|
| Pinhole | $r = f\tan\theta$ | an idealisation — fails badly past ~30° |
| Ideal fisheye | $r = f\theta$ | the general shape of a fisheye's behaviour |
| **This lens** | $r = f\theta(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8)$ | the actual OV9281 unit, fitted by calibration |

The four coefficients $k_1 \ldots k_4$ are exactly the correction from the middle row to
the bottom one: set them all to zero and the equation collapses back to $r = f\theta$.
They are small numbers — ours are $(0.33, 0.56, -1.40, 1.25)$ — because the ideal fisheye
is already close; they are fitting the residual.

Why a polynomial in $\theta^2, \theta^4, \ldots$ rather than any other function: a lens is
radially symmetric, so the correction can only depend on how far off-axis the ray is, never
on direction. Odd powers would break that symmetry (they change sign when $\theta$ does),
so only even powers appear. Beyond that, it is simply a flexible curve with enough freedom
to trace a real lens's behaviour and few enough terms to fit from a few dozen chessboard
images.

OpenCV provides two distortion families:

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

**Where this goes next.** We now have an accurate description of how this lens bends light.
There are two ways to use it, and the choice matters for everything downstream:

1. **Keep the raw image and carry the distortion model through every later calculation.**
   Every marker detection, every pose solve, every projection would have to apply the
   polynomial. Nothing is thrown away, but all downstream maths gets harder.
2. **Undo the distortion once, straight after capture, and hand a clean pinhole image to
   everything else.** Then §0's simple equations apply unchanged for the rest of the
   pipeline.

`main.py` does the second, which is what §2 describes. That is why every later `solvePnP`
call passes zeros for the distortion coefficients — by then, the distortion is already gone.

---

## 2. Image undistortion — straightening the fisheye

`main.py` builds an undistortion map once at startup:

```python
self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
    K, D, np.eye(3), K, frame_size, cv2.CV_16SC2
)
```

This precomputes, for every output pixel $(u', v')$ in the corrected (pinhole-equivalent)
image, the source coordinate $(u, v)$ to sample from in the raw fisheye image.

**The map equation.** For each output pixel $(u', v')$, five steps:

$$
\text{1. normalise:} \qquad x' = \frac{u' - c_x}{f_x}, \qquad y' = \frac{v' - c_y}{f_y}
$$

$$
\text{2. radius and ray angle:} \qquad r' = \sqrt{x'^2 + y'^2}, \qquad \theta = \arctan(r')
$$

$$
\text{3. apply the lens polynomial:} \qquad \theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right)
$$

$$
\text{4. rescale radially:} \qquad x_d = \frac{\theta_d}{r'}\, x', \qquad y_d = \frac{\theta_d}{r'}\, y'
$$

$$
\text{5. back to pixels:} \qquad \boxed{\;u = f_x x_d + c_x, \qquad v = f_y y_d + c_y\;}
$$

Those $(u, v)$ are stored as `map1[v'][u']` and `map2[v'][u']`. (At $r' = 0$ the ratio
$\theta_d / r'$ is taken as its limit, 1 — the centre pixel maps to itself.)

**Why it is built output-first.** Notice that every step above is a *forward* evaluation:
the polynomial is applied, never inverted. That is deliberate. Going the other way — from a
raw pixel to where it should move — would require solving
$\theta_d = \theta(1 + k_1\theta^2 + \ldots)$ for $\theta$, a root-find with no closed form,
per pixel. By starting from the output grid and asking "where did this pixel come from?",
the awkward inversion never has to happen. This is the standard trick for image warping:
iterate over the destination, not the source.

It also guarantees every output pixel gets exactly one value — no gaps or overlaps, which is
what you would get by pushing source pixels forward into the output.

The output is `map1, map2` — two arrays the size of the output image storing those source
coordinates. Both are computed once at startup, since $\mathbf{K}$ and $\mathbf{D}$ never
change.

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

## 6. Combining markers into one position

The device carries markers on several faces (IDs 12 front, 14 front-top, 20/24 back
sides, plus 4, 8, 28, 32 on the reprint); typically 1–3 are visible per frame. There
are two ways to turn those detections into one grip position. **The joint rigid-body
solve (§6.1) is what runs today**; the per-marker average (§6.2) is the superseded
method, kept because it is the fallback when board geometry is missing, and because
it is the baseline the comparison in [rigid_body_math.md](rigid_body_math.md) measures
against.

### 6.1 Joint rigid-body solve — deployed

The markers are glued to one rigid object, so their poses relative to each other are
physical constants. `calibrate_board.py` measures them once (§6.3) and stores, for
each marker $i$, its fixed pose in the **board frame**:

$$
{}_{\text{board}}\mathbf{X} = \mathbf{R}^{b}_{i}\, {}_{\text{mkr}_i}\mathbf{X} + \mathbf{t}^{b}_{i}
$$

Applying this to the four known corner coordinates $\mathbf{X}_k$ of each marker gives
every corner's fixed position on the device:

$$
{}_{\text{board}}\mathbf{X}_{i,k} = \mathbf{R}^{b}_{i} \mathbf{X}_k + \mathbf{t}^{b}_{i}
$$

These constants live in `board_geometry.json`, together with one consensus grip point
${}_{\text{board}}\mathbf{g}$.

At runtime, whatever subset $V$ of markers is visible, **all** their corners go into a
single PnP problem with **one** unknown pose $(\mathbf{R}, \mathbf{t})$ — the pose of
the whole device:

$$
\min_{\mathbf{R},\, \mathbf{t}} \; \sum_{i \in V} \sum_{k=1}^{4}
\left\| \operatorname{project}\!\left(\mathbf{K},\; \mathbf{R}\, {}_{\text{board}}\mathbf{X}_{i,k} + \mathbf{t}\right) - \mathbf{u}_{i,k} \right\|^2
$$

The grip point then follows directly — no voting, no averaging:

$$
{}_{\text{cam}}\mathbf{g} = \mathbf{R}\, {}_{\text{board}}\mathbf{g} + \mathbf{t}
$$

**Why this is better.** With three markers visible, the old way solved 3 separate
6-unknown problems from 8 measurements each ($8/6 \approx 1.3$ constraint ratio, each
point set coplanar). The joint solve has 24 measurements against 6 unknowns (ratio 4)
over a non-coplanar point set. Two things follow:

- **Depth precision scales with the pixel span of the measured shape.** A single marker
  spans ~90 px in the image; the whole device spans ~250 px. Depth is read from how
  much that span *shrinks*, so a wider constellation resolves depth ~3× better from the
  same corner noise — on top of the $\sqrt{3}$ from pooling more corners.
- **The two-tilt ambiguity dies.** That failure mode is a property of *coplanar* point
  sets. The device's faces are angled, so the mirrored pose projects visibly wrongly and
  the second minimum disappears whenever ≥ 2 non-parallel markers are visible.

Measured on 43 workspace positions: median device wobble at rest fell from 3.27 mm to
0.78 mm, a 5.2× reduction (`tools/analyze_jitter.py`).

**Degradation:** with only one marker visible the problem necessarily reduces to
single-marker quality — the geometry cannot supply constraints the image doesn't have.

### 6.2 Per-marker average — superseded

For each visible marker $i$, `solvePnP` gives $\mathbf{R}_i, \mathbf{t}_i$, and a
hand-measured offset ${}_{\text{mkr}_i}\mathbf{o}_i$ points from that marker's centre to
the grip. Each marker independently predicts the grip position:

$$
{}_{\text{cam}}\mathbf{g}_i = \mathbf{R}_i \cdot {}_{\text{mkr}_i}\mathbf{o}_i + \mathbf{t}_i
$$

and the predictions are combined by a weighted mean:

$$
{}_{\text{cam}}\mathbf{g} = \frac{\sum_{i \in V} w_i\, {}_{\text{cam}}\mathbf{g}_i}{\sum_{i \in V} w_i}
\qquad w_i = \text{projected pixel area of marker } i
$$

(The original code used equal weights, $w_i = 1$; pixel-area weighting was added later on
the reasoning that a marker appearing larger has proportionally more precise corners. The
`SETUP:...,equal` command restores equal weighting — that is how the old setup is
reconstructed for comparison.)

Three structural weaknesses, all of which §6.1 removes:

1. **Each solve is weakly constrained** — 8 measurements, 6 unknowns, and the four points
   are coplanar, so depth rests on sub-pixel size changes of one small square.
2. **The lever arm amplifies rotation error.** Each $\mathbf{R}_i$ is uncertain, and that
   uncertainty is multiplied by the offset length $\|\mathbf{o}_i\|$ before reaching the
   grip — a marker 12 cm from the grip converts a 1° rotation error into ~2 mm of
   position error.
3. **Disagreement is averaged, not resolved.** Physically impossible disagreement between
   markers (they are rigidly joined, so they *cannot* truly disagree) is smoothed after
   the fact rather than used as evidence during the solve.

### 6.3 Where the board geometry comes from

`calibrate_board.py` never uses `MARKER_OFFSETS` — it measures the layout directly, so
the result stays valid even if a hand-measured offset is wrong. In every frame where two
markers $i$ and $j$ are both visible, each is solved independently and combined so that
the camera cancels out:

$$
\mathbf{R}_{ij} = \mathbf{R}_i^\top \mathbf{R}_j
\qquad
\mathbf{t}_{ij} = \mathbf{R}_i^\top (\mathbf{t}_j - \mathbf{t}_i)
$$

$(\mathbf{R}_{ij}, \mathbf{t}_{ij})$ is a fact about the device alone. Samples are
rejected if the fit is poor or the mirrored tilt fits nearly as well, then ≥ 30 surviving
samples per pair are averaged with outlier trimming (`pose_averaging.py`).

Markers that never appear together (front and back cannot face one camera at once) are
linked by **composing** through a shared neighbour:

$$
\mathbf{R}_{ik} = \mathbf{R}_{ij}\mathbf{R}_{jk}
\qquad
\mathbf{t}_{ik} = \mathbf{R}_{ij}\mathbf{t}_{jk} + \mathbf{t}_{ij}
$$

Walking outward from the reference marker this way puts every marker in one common frame.

**Self-check before saving:** each marker independently predicts the grip point via its
own offset, ${}_{\text{board}}\mathbf{g}_i = \mathbf{R}^{b}_i \mathbf{o}_i + \mathbf{t}^{b}_i$.
All predictions should land on the same physical spot; the script prints each one's
distance from their mean and flags any beyond 5 mm — a disagreement means either the
solved geometry or that hand-measured offset is wrong.

---

## 7. World-frame transformation — reporting position relative to a fixed origin

The grip point above is in the **camera frame** — useless to the game, which wants
positions relative to a fixed reference. So the tracker **locks** a world origin.

**At lock time**, two quantities are saved, both expressed in the camera frame:

$$
\mathbf{R}_{\text{lock}} \;=\; \text{the device's orientation at lock}
\qquad
{}_{\text{cam}}\mathbf{g}_{\text{lock}} \;=\; \text{the grip point at lock}
$$

In rigid-body mode both come straight from the board pose
($\mathbf{R}_{\text{lock}} = \mathbf{R}$, ${}_{\text{cam}}\mathbf{g}_{\text{lock}} = \mathbf{R}\,{}_{\text{board}}\mathbf{g} + \mathbf{t}$),
so the axes belong to the **device as a whole** — not to whichever marker happened to be
seen first, which was the caveat of the per-marker version.

**Every subsequent frame**, the displacement from the locked point is rotated into the
locked frame:

$$
{}_{\text{world}}\mathbf{p} = \mathbf{R}_{\text{lock}}^\top \left( {}_{\text{cam}}\mathbf{g}_{\text{lock}} - {}_{\text{cam}}\mathbf{g} \right)
$$

That is the 3D position streamed to Godot: how far, and in what direction, the grip has
moved since lock time.

**Locking is validated, not taken from one frame.** The lock only commits after
`ORIGIN_LOCK_FRAMES` = 10 consecutive frames in which the same marker set is detected and
mean corner motion stays below `ORIGIN_STABLE_PX` = 2 px (in dual-camera mode the gate is
pose-space instead: translation and rotation deltas below `origin_stable_m` /
`origin_stable_rad`). This prevents anchoring the entire session to a single noisy
detection.

**The lock persists across restarts.** $(\mathbf{R}_{\text{lock}}, {}_{\text{cam}}\mathbf{g}_{\text{lock}})$
are written to `origin_lock.json` and reloaded on startup. Because they are stored **in the
camera frame**, they stay valid as long as the camera does not move — which is what makes
sessions (and patients, on an identically-mounted rig) comparable to each other. Two
consequences worth knowing:

- Moving the camera silently invalidates the file: it still loads, but no longer describes
  reality. Delete it and re-lock (the installer's origin ritual sends `RELOCK`).
- Because the lock is camera-frame, data recorded under *different* locks can still be
  reconciled afterwards — invert the transform to recover camera-frame coordinates:

$$
{}_{\text{cam}}\mathbf{g} = {}_{\text{cam}}\mathbf{g}_{\text{lock}} - \mathbf{R}_{\text{lock}}\, {}_{\text{world}}\mathbf{p}
$$

This is why every logged data file stamps the contents of `origin_lock.json` in its header
(see [v1_plan.md §5](v1_plan.md)) — the stamp is the undo key.

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
