

End-to-end derivation of how a raw fisheye camera frame becomes a 3D position broadcast to Godot. Walks every stage of `main.py` in execution order, with the equations OpenCV is solving under each function call.

> **Scope.** This is the pipeline reference — every stage, in order, as deployed.
> §7 and §8 were updated 2026-07-28 for the joint rigid-body solve and the validated,
> persistent origin lock; §4 onward was rewritten 2026-08-01 to derive rather than assert
> (homography, total least squares, the Hamming bound, the Kalman gain, inverse-variance
> weighting), to add the dual-camera fusion of §7.4, and to correct §6.5, which named the
> wrong solver. For the focused *why the new method beats the old* argument
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
| Camera calibration (`calibrate_camera.py`) | $f_x, f_y, c_x, c_y$ and $k_1 \ldots k_4$ → `camera_calib.toml` | §2 |
| Board calibration (`calibrate_board.py`) | where each marker sits on the device → `board_geometry.json` | §7.3 |

Both invert the same logic as tracking, but with the unknowns swapped: photograph something
whose 3D geometry is *known* (a chessboard of measured squares; markers on a rigid device),
and solve for the constants instead of the pose. Get these wrong and every stage below
inherits the error silently — the pipeline will still run and still produce plausible
numbers.

The order below reflects that dependency. Sections 0 and 1 build the forward model and
state what its parameters *are*; §2 measures them; from §3 onward the model is used:

| § | Stage | What it contributes |
|---|---|---|
| 0 | Pinhole model | The forward model in its simplest form: 3D point → pixel, via four constants. Exact near the image centre. |
| 1 | Lens distortion | Completes the forward model: our 160° lens deviates at the edges, and four more coefficients describe how. |
| 2 | **Calibration** | Measures all of those parameters for this specific camera. Everything above is unusable until this is done. |
| 3 | Undistortion | Undo the lens deviation once per frame, so every later stage can use §0's simple equations and ignore the lens. |
| 4 | Marker detection | Find the black-and-white squares in the image and read their IDs — the raw evidence. |
| 5 | Corner refinement | Locate each corner to sub-pixel precision. Everything downstream inherits this accuracy. |
| 6 | Pose estimation | **The inversion.** Search for the pose whose projected corners best match the detected ones. |
| 7 | Combining markers | Fuse all visible markers — and, in dual-camera mode, both cameras — into one device pose. |
| 8 | World frame | Re-express that pose relative to a fixed, locked origin, so numbers mean the same thing across sessions. |
| 9 | Filtering | Smooth the frame-to-frame result before it drives the game. |
| 10 | Transport | Pack the position into a UDP datagram and send it to Godot. |
| 11 | Screen mapping | Godot's 2D affine fit from workspace coordinates to cursor pixels. |

Two threads run through all of it. **Accuracy compounds**: a fraction of a pixel of corner
error in §5 becomes millimetres of position error by §8 — §5.1 derives the exchange rate,
$\delta Z = (Z/p)\,\delta p$, and it is quoted in four later sections. And **each stage
exists to let the next one stay simple** — undistortion is done so pose estimation can
pretend the lens is perfect; board calibration is done so pose estimation can treat many
markers as one object.

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
wrong in the same way. The search itself is §6.

The chain in this section runs: coordinate frame → the projection itself → converting to
pixels → shifting the origin to the image corner → the same thing in matrix notation →
what the model assumes, and why a 160° lens breaks those assumptions (leading into §1).

Throughout this section the four constants $f_x, f_y, c_x, c_y$ are treated as known.
Where they actually come from is §2 — deferred until §1 has introduced the rest of the
parameters, since calibration measures them all in one fit.

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

**What this frame assumes.** Everything in §0 and §1 takes the 3D point as *already*
expressed in the camera frame. Every bare $(X, Y, Z)$ in those two sections means
${}_{\text{cam}}\mathbf{X}$ from the notation table — the subscript is dropped only because
these sections never work in any other frame.

That is a real restriction, because nothing in the scene arrives in camera coordinates. A
marker's corners are known in the *marker's* frame (§6); a corner of the device is known in
the *board* frame (§7); the game needs positions in a fixed *world* frame (§8). Moving a
point from any of those into the camera frame takes a rotation and a translation:

$$
{}_{\text{cam}}\mathbf{X} = \mathbf{R}\, {}_{\text{world}}\mathbf{X} + \mathbf{t}
$$

So the complete chain from a physical point to a pixel has four arrows, and §0 and §1 build
only the last three:

$$
{}_{\text{world}}\mathbf{X}
\;\xrightarrow{\;\mathbf{R},\, \mathbf{t}\;}\;
{}_{\text{cam}}\mathbf{X}
\;\xrightarrow{\;\div Z\;}\;
(a, b)
\;\xrightarrow{\;\mathbf{D}\;}\;
(x_d, y_d)
\;\xrightarrow{\;\mathbf{K}\;}\;
(u, v)
$$

| Arrow | What it is | Status | Covered in |
|---|---|---|---|
| $\mathbf{R}, \mathbf{t}$ | rigid transform, 6 numbers | **the unknown** — different every frame | §6, §7, §8 |
| $\div Z$ | perspective division, no parameters | fixed geometry | §0.2 |
| $\mathbf{D}$ | lens warp, 4 numbers | fixed property of the lens | §1, measured in §2 |
| $\mathbf{K}$ | intrinsics, 4 numbers | fixed property of the camera | §0.6, measured in §2 |

**Why $\mathbf{R}$ and $\mathbf{t}$ are absent from the next two sections.** Not an omission
— they are a different kind of quantity. $\mathbf{K}$ and $\mathbf{D}$ are properties of the
hardware: measured once, then constant forever. $\mathbf{R}$ and $\mathbf{t}$ are properties
of *where the object currently is*, recomputed every frame. They are what the pipeline
**outputs**, not something fed into it. They first appear in §6, as the unknowns of

$$
\lambda \begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
= \mathbf{K}\left(\mathbf{R}\, {}_{\text{mkr}}\mathbf{X} + \mathbf{t}\right)
$$

$\lambda$ is not a ninth parameter. It is the depth of the point in the camera frame, and it
appears because this is an equality *up to scale*: $\mathbf{K}(\cdots)$ returns a 3-vector
whose third component is that depth, and the pixel is what you get after dividing the first
two by it. Writing $\lambda$ on the left **defers** the $\div Z$ arrow rather than performing
it — which keeps both sides linear in $\mathbf{R}$ and $\mathbf{t}$, the property §6.2's
solver depends on.

Either way, the $\mathbf{K}$ half is exactly what §0 and §1 exist to construct. Build the right-hand
arrows accurately, and the left-hand one becomes solvable.

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
the other transforms in the pipeline (§6, §8) and is what OpenCV expects as an argument.

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
problem is inverted (§6).

In code, either form works — dividing first, or dividing after:

```python
# ratios first (division done by hand)
projected = K @ np.array([X / Z, Y / Z, 1.0])
u, v = projected[0], projected[1]

# raw point, then homogeneous normalisation
projected = K @ np.array([X, Y, Z])
u, v = projected[0] / projected[2], projected[1] / projected[2]
```

### 0.7 What the model assumes — and why a 160° lens breaks it

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

§0.7 introduced a second rung: the pinhole model puts a ray at $r = f\tan\theta$, while a
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

### 1.1 The complete forward model — camera frame to pixel

*"Complete" is scoped to the camera. As in §0, the input $(X, Y, Z)$ is a point already in the
camera frame, ${}_{\text{cam}}\mathbf{X}$; the $\mathbf{R}, \mathbf{t}$ that bring a point into
that frame are the tracker's unknown, not the camera's parameters, and are solved in §6
(§0.1).*

§0 ended with the projection written as a single matrix multiply by $\mathbf{K}$. That form
is now incomplete: $\mathbf{K}$ contains only the pinhole constants, and a real lens applies
a warp that no $3 \times 3$ matrix can express. The full camera-frame model has three stages,
and only the last is linear:

$$
\underbrace{(X, Y, Z) \;\longrightarrow\; \left(\tfrac{X}{Z}, \tfrac{Y}{Z}\right)}_{\text{1. perspective division}}
\;\longrightarrow\;
\underbrace{(x_d, y_d)}_{\text{2. lens warp}}
\;\longrightarrow\;
\underbrace{(u, v)}_{\text{3. } \mathbf{K}}
$$

Written out in full, the projection of a 3D point in the camera frame is now:

$$
a = \frac{X}{Z}, \qquad b = \frac{Y}{Z}, \qquad r = \sqrt{a^2 + b^2}, \qquad \theta = \arctan(r)
$$

$$
\theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right)
$$

$$
x_d = \frac{\theta_d}{r}\, a, \qquad y_d = \frac{\theta_d}{r}\, b
$$

$$
\boxed{\;u = f_x\, x_d + c_x, \qquad v = f_y\, y_d + c_y\;}
$$

Compare with §0's version, $u = f_x \cdot (X/Z) + c_x$: the *only* change is that the raw
ratio $X/Z$ has been replaced by the warped $x_d$. Set all $k_i = 0$ and $\theta_d = \theta$,
which for small angles gives $x_d \to a$ and recovers §0 exactly. So the pinhole model is
not wrong, it is the zero-distortion special case.

**The full parameter set is therefore eight numbers:**

$$
\underbrace{f_x,\; f_y,\; c_x,\; c_y}_{\mathbf{K} \text{ — intrinsics}}
\qquad
\underbrace{k_1,\; k_2,\; k_3,\; k_4}_{\mathbf{D} \text{ — distortion}}
$$

They are what `camera_calib.toml` holds, and §2 is how they are obtained. Note that they
cannot be measured separately — the same chessboard fit produces all eight at once, because
each one's best value depends on the others.

**The whole thing as one equation.** The radial warp is a scaling of both coordinates by the
same factor $\theta_d / r$, so it can be written as a diagonal matrix and placed directly
next to $\mathbf{K}$:

$$
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
=
\underbrace{
\begin{bmatrix} f_x & 0 & c_x \\ 0 & f_y & c_y \\ 0 & 0 & 1 \end{bmatrix}
}_{\mathbf{K}}
\underbrace{
\begin{bmatrix} \dfrac{\theta_d}{r} & 0 & 0 \\[6pt] 0 & \dfrac{\theta_d}{r} & 0 \\[6pt] 0 & 0 & 1 \end{bmatrix}
}_{\mathbf{S}(\theta) \;-\; \text{lens warp}}
\begin{bmatrix} X/Z \\ Y/Z \\ 1 \end{bmatrix}
$$

$$
\text{where} \quad
r = \sqrt{\left(\tfrac{X}{Z}\right)^2 + \left(\tfrac{Y}{Z}\right)^2},
\quad
\theta = \arctan r,
\quad
\theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right)
$$

**Where the $k$ coefficients actually sit.** They are inside $\theta_d$, so they never appear
in the matrix as written — the whole distortion model is compressed into the single entry
$\theta_d / r$. Substituting the definitions back in, that one entry is:

$$
\frac{\theta_d}{r}
=
\frac{\arctan r \,\left(1 + k_1 \arctan^2 r + k_2 \arctan^4 r + k_3 \arctan^6 r + k_4 \arctan^8 r\right)}{r}
$$

which is why it is normally abbreviated. Written this way the eight parameters are all on
the page: $f_x, f_y, c_x, c_y$ in $\mathbf{K}$, and $k_1 \ldots k_4$ in that entry. Note
they enter *completely differently* — the intrinsics are plain multipliers and offsets, while
the $k$'s sit inside a nonlinear function of the point's own radius. Only the intrinsics can
live in a constant matrix.

$\mathbf{K}$ is constant. $\mathbf{S}$ is not — its entries depend on $r$, which depends on
the point being projected. That is exactly what makes the model nonlinear: you cannot
multiply $\mathbf{K}\mathbf{S}$ once and reuse the product, because $\mathbf{S}$ is
different for every point.

Set $k_1 \ldots k_4 = 0$ and the bracket becomes 1, leaving $\theta_d / r = \arctan(r)/r$.
For small angles $\arctan r \approx r$, so $\mathbf{S} \to \mathbf{I}$ and the equation
collapses to §0.6's pinhole form.

### 1.2 Where this goes next

We now have an accurate description of how this lens bends light.
There are two ways to use it, and the choice matters for everything downstream:

1. **Keep the raw image and carry the distortion model through every later calculation.**
   Every marker detection, every pose solve, every projection would have to apply the
   polynomial. Nothing is thrown away, but all downstream maths gets harder.
2. **Undo the distortion once, straight after capture, and hand a clean pinhole image to
   everything else.** Then §0's simple equations apply unchanged for the rest of the
   pipeline.

`main.py` does the second, which is what §3 describes. That is why every later `solvePnP`
call passes zeros for the distortion coefficients — by then, the distortion is already gone.

---

## 2. Calibration — measuring the eight parameters

The forward model is now complete but unusable: it has eight unknown constants that belong
to one physical camera unit. Calibration determines them, once, offline
(`calibrate_camera.py`).

**What calibration is.** The eight numbers are not published anywhere and cannot be looked
up. They are properties of one particular sensor bonded to one particular lens, and two
cameras off the same production line differ by enough to matter at millimetre precision. So
you measure them — the same way you would check an unmarked kitchen scale by putting a known
1 kg weight on it and seeing what it reads. Photograph an object whose real size you already
know, compare the picture against what the model *would* have predicted, and adjust the eight
numbers until prediction and photograph agree. The known object is a printed chessboard: its
corners lie on an exact grid, so once you have measured a single square, every corner's
position on the board follows.

**What you actually do.** Print the OpenCV 9×6 chessboard, measure one square with calipers,
put that number in `SQUARE_SIZE_M` (currently 24.35 mm), and run the script on the Pi.

On every frame it runs `cv2.findChessboardCorners` with flags
`CALIB_CB_ADAPTIVE_THRESH | CALIB_CB_FAST_CHECK`. That call is all-or-nothing: it returns all
$9 \times 6 = 54$ inner corners or none. When it succeeds, the corners are refined by
`cv2.cornerSubPix` over an 11×11 search window, stopping at 30 iterations or a 0.01 px
improvement.

A frame is then captured automatically when both of these hold:

| Condition | Constant | Value |
|---|---|---|
| board has been near-motionless this many consecutive frames | `STABLE_FRAMES` | 15 |
| …where "near-motionless" means mean corner motion below | `STABLE_PX_THRESHOLD` | 2.0 px |
| and this long has elapsed since the previous capture | `COOLDOWN_S` | 2.0 s |

"Near-motionless" is measured rather than eyeballed. `StabilityTracker` holds the last 15
corner sets; for each of the 14 consecutive pairs it computes how far each of the 54 corners
moved and averages that over the corners; it then averages those 14 numbers and requires the
result to be under 2.0 px. After every capture the history is cleared, so the next one needs
15 fresh frames before it can trigger.

Capturing stops at `NUM_CAPTURES = 20`. If you quit early with fewer than 10, the script
aborts instead of fitting. The 2.0 s cooldown puts a hard floor of 40 s on the capture phase;
in practice it takes longer, since you are repositioning the board between snaps.

That repositioning is the part that matters: move the board near and far, tilted left and
right, up and down, and out into the corners of the view. Twenty photographs of the same thing
are worth far less than twenty different ones, for the reasons below.

**The function.** All the fitting happens in one call, in `run_calibration()`:

```python
rms, K, D, _, _ = cv2.fisheye.calibrate(
    objpoints, imgpoints, FRAME_SIZE, K, D, rvecs, tvecs,
    flags,
    (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 1e-6),
)
```

Note it is `cv2.fisheye.calibrate`, not the general `cv2.calibrateCamera`. Those fit two
different distortion models, and the general one is the wrong shape for a lens this wide. The
choice is recorded as `method = "fisheye"` in the output file so nothing downstream has to
guess.

**What goes in:**

| Argument | Type | Shape / dtype | Contents |
|---|---|---|---|
| `objpoints` | `list` of 20 arrays | each `(1, 54, 3)` `float32` | where each corner sits *on the board*, in metres |
| `imgpoints` | `list` of 20 arrays | each `(1, 54, 2)` `float64` | where each corner was *seen*, in pixels |
| `FRAME_SIZE` | `tuple` of 2 `int` | `(1280, 800)` | image width, height |
| `K` | array | `(3, 3)` `float64` | zeros — a placeholder OpenCV overwrites |
| `D` | array | `(4, 1)` `float64` | zeros — placeholder |
| `rvecs`, `tvecs` | `list` of 20 arrays | each `(1, 1, 3)` `float64` | zeros — placeholders for the 20 board poses |
| `flags` | `int` | — | bitwise OR of the three constants below |
| criteria | `tuple` | `(int, int, float)` | `(TERM_CRITERIA_EPS + TERM_CRITERIA_MAX_ITER, 30, 1e-6)` — stop at 30 iterations or a `1e-6` improvement |

The 20 is `len(imgpoints)`, i.e. `NUM_CAPTURES`; the 54 is $9 \times 6$, the inner corners of
the board. `K`, `D`, `rvecs` and `tvecs` go in as zero-filled arrays purely because the Python
binding takes them as in-out parameters — their *contents* are ignored (no
`CALIB_USE_INTRINSIC_GUESS` flag is set), only their shapes matter.

`objpoints` is the same array repeated 20 times, because the board is physically identical in
every shot. It is built by `make_object_points()`, and corner $k$ holds

```
x = (k  % 9) * 0.02435       # column index × square size
y = (k // 9) * 0.02435       # row index    × square size
z = 0.0                      # always — the board is flat
```

so it runs `(0, 0, 0)`, `(0.02435, 0, 0)`, … along the first row of 9, then wraps. That
ordering matches the order `findChessboardCorners` returns pixels in, which is what makes the
two lists correspond element by element.

The three flags, all from the `cv2.fisheye` namespace:

| Flag | What setting it does | What happens if it is not set |
|---|---|---|
| `CALIB_FIX_SKEW` | holds `K[0,1]` at exactly 0 throughout, so skew is never a free parameter and the fit has 8 unknowns rather than 9 | skew is estimated as a 9th intrinsic; on a sensor whose pixel axes are perpendicular it lands near 0 anyway, having absorbed some noise on the way |
| `CALIB_RECOMPUTE_EXTRINSIC` | re-solves all 20 board poses from the current `K` and `D` on every iteration | the board poses from the initial estimate are held fixed and only the intrinsics are refined — faster, and less accurate |
| `CALIB_CHECK_COND` | tests the conditioning of the system each iteration and raises `cv2.error` if it degrades past OpenCV's internal threshold | an ill-conditioned capture set returns normally, with parameters that look unremarkable |

`CALIB_CHECK_COND` is the one to know about, because it converts a silent failure into a loud
one. OpenCV's exception names the offending capture — *"CALIB_CHECK_COND - Ill-conditioned
matrix for input array 7"* — and `main()` catches it, prints that message, and adds its own
hint: *"not enough variation in board poses. Re-run and tilt more."* A calibration that
refuses to finish is the good outcome. The bad one is a set that barely converges and returns
plausible-looking numbers.

**What comes out:** five values, `rms, K, D, rvecs, tvecs`. For our camera:

$$
\mathbf{K} =
\begin{bmatrix} f_x & 0 & c_x \\ 0 & f_y & c_y \\ 0 & 0 & 1 \end{bmatrix}
=
\begin{bmatrix} 887.261 & 0 & 654.008 \\ 0 & 889.980 & 348.839 \\ 0 & 0 & 1 \end{bmatrix}
\qquad
\mathbf{D} =
\begin{bmatrix} k_1 \\ k_2 \\ k_3 \\ k_4 \end{bmatrix}
=
\begin{bmatrix} 0.3303 \\ 0.5552 \\ -1.4004 \\ 1.2545 \end{bmatrix}
$$

$$
\text{rms} \;=\; \sqrt{\frac{1}{20 \times 54} \sum_{j=1}^{20} \sum_{i=1}^{54}
\big\| \mathbf{u}_{ij} - \hat{\mathbf{u}}_{ij} \big\|^2} \;=\; 0.627 \text{ px}
$$

where $\mathbf{u}_{ij}$ is the detected pixel of corner $i$ in capture $j$ and
$\hat{\mathbf{u}}_{ij}$ is where the fitted model projects that corner to.

$$
\mathbf{rvec}_j, \; \mathbf{tvec}_j \in \mathbb{R}^3, \quad j = 1 \ldots 20
\qquad
\mathbf{R}_j = \exp\!\left(\left[\mathbf{rvec}_j\right]_\times\right)
$$

the pose of the board in capture $j$ — Rodrigues vector and translation in metres. Both are
**discarded** (`_, _`): they record where you happened to hold a chessboard on one afternoon.
Only $\mathbf{K}$ and $\mathbf{D}$, which describe the camera, are kept.

For our camera: $f_x = 887.3$, $f_y = 890.0$, $c_x = 654.0$, $c_y = 348.8$, and
$\mathbf{D} = (0.33,\; 0.56,\; -1.40,\; 1.25)$, at $\text{rms} = 0.63$ px. All of it is
written to `camera_calib.toml`.

**What the call is doing.** Each of the 20 images was taken with the board somewhere
different, so each contributes its own unknown board position — but all 20 share the *same*
camera. Everything is solved together, by making the model's predicted corners land as close
as possible to the corners actually detected, across every image at once:

$$
\min_{\substack{f_x, f_y, c_x, c_y,\; \mathbf{D} \\ \{\mathbf{R}_j, \mathbf{t}_j\}}}
\;\sum_{j=1}^{N_{\text{images}}} \;\sum_{i=1}^{N_{\text{corners}}}
\left\| \; \mathbf{u}_{ij} \;-\; \pi\!\left(\mathbf{X}_i; \; \mathbf{R}_j, \mathbf{t}_j, \; \mathbf{K}, \mathbf{D}\right) \right\|^2
$$

where $\mathbf{X}_i$ are the known board corners, $\mathbf{u}_{ij}$ the corners actually
detected in image $j$, and $\pi(\cdot)$ is the complete forward model of §1.1. In words:
**find the camera parameters and board poses that best explain every corner in every image
simultaneously.**

This is also why the parameters cannot be measured one at a time. A slightly wrong $c_x$ can
be hidden by a compensating error in $k_1$, so the best value of each depends on the others,
and only solving for all of them together resolves it.

**Why the poses must vary.** Two reasons, and both cause silent failures rather than obvious
ones.

The distortion coefficients describe what happens at the *edges* of the image, so they can
only be learnt from corners that actually appear near the edges. Twenty captures with the
board comfortably in the middle leave those four numbers barely constrained — and the fit will
then be confidently wrong in exactly the region §1's table showed to be most extreme.

The second reason is subtler. A board held flat and facing the camera looks exactly the same
when it is large and far away as when it is small and close: those two possibilities produce
identical pixels, so from flat views alone the focal length and the distance cannot be told
apart. Tilting the board fixes this, because one edge is then genuinely nearer than the other
and the board photographs as a trapezoid — a shape that depends on true distance in a way no
change of focal length can fake. This is what `CALIB_CHECK_COND` is checking for, and why its
error message asks specifically for more tilt.

**How it is verified.** Two numbers, and the second is the one to trust.

The first is `rms`, defined above — 0.627 px here, and under about 1 px is good. Two
properties of it matter. Being a root-mean-square rather than a mean, it is always the larger
of the two and a few badly-placed corners move it much more than they would move an average.
And it is evaluated over the same 1080 corners that the fit minimised, so it measures *how
well the model fits the data it was given*, which is not the same as the model being right.

The second is the **verify phase** (`NUM_VERIFY_POSES = 6`), which runs automatically after
saving. It asks for six fresh poses and, for each, rebuilds the board in 3D using the
calibration that was just fitted, then measures the squares it rebuilt. Because you know what
a square really measures, the error lands directly in millimetres.

Per pose, in order:

1. Detect the 54 corners, refine with `cornerSubPix`, undistort with
   `cv2.fisheye.undistortPoints`.
2. `cv2.solvePnP` for that pose, giving $\mathbf{R}$ and $\mathbf{t}$.
3. Take the board plane from that pose:

$$
\mathbf{n} = \mathbf{R}[:,2], \qquad d = \mathbf{t} \cdot \mathbf{n}
$$

| Symbol | Meaning |
|---|---|
| $\mathbf{R}$ | $3 \times 3$ rotation from step 2; turns board coordinates into camera coordinates |
| $\mathbf{t}$ | position of the board's origin in the camera frame, metres |
| $\mathbf{n}$ | unit normal of the board plane, in camera coordinates |
| $d$ | perpendicular distance from the camera centre to the board plane, metres |

$\mathbf{n}$ is $\mathbf{R}$'s **third column** because the board is flat. `make_object_points()`
leaves $z = 0$ for all 54 corners, so the board *is* its own $xy$-plane, and the normal of that
plane is its $z$-axis. Since $\mathbf{R}\,(0,0,1)^\top$ picks out the third column,
$\mathbf{R}[:,2]$ is that $z$-axis expressed in camera coordinates. It has unit length because
$\mathbf{R}$ is a rotation, which is what makes $d$ a true distance rather than a scaled one.
And $d = \mathbf{t} \cdot \mathbf{n}$ because $\mathbf{t}$ is a known point *on* the plane, so
its component along the normal is the plane's offset. (If the board's $z$-axis happens to point
away from the camera both $d$ and $\mathbf{r}_j \cdot \mathbf{n}$ change sign, and the ratio in
step 4 is unaffected.)

4. Turn each corner pixel back into a 3D point by intersecting its ray with that plane:

$$
\mathbf{r}_j = \mathbf{K}^{-1} \begin{bmatrix} u_j \\ v_j \\ 1 \end{bmatrix},
\qquad
\hat{\mathbf{X}}_j = \underbrace{\frac{d}{\mathbf{r}_j \cdot \mathbf{n}}}_{\lambda_j} \; \mathbf{r}_j
$$

| Symbol | Meaning |
|---|---|
| $(u_j, v_j)$ | undistorted pixel coordinates of corner $j$, from step 1 |
| $\mathbf{r}_j$ | direction of the ray through that pixel, camera frame — a direction, not unit length |
| $\lambda_j$ | the scale along that ray that lands on the board plane |
| $\hat{\mathbf{X}}_j$ | reconstructed 3D position of corner $j$, camera frame, metres |

Substituting $\hat{\mathbf{X}}_j = \lambda_j \mathbf{r}_j$ into the plane condition
$\hat{\mathbf{X}}_j \cdot \mathbf{n} = d$ gives $\lambda_j (\mathbf{r}_j \cdot \mathbf{n}) = d$,
hence the quotient above. This is §6.1's unknown $\lambda$ finally being pinned down — the
plane is the outside information that turns a ray into a point.

5. Measure every **adjacent pair** of reconstructed points against the known square size:

$$
e_{ij} = \big| \; \| \hat{\mathbf{X}}_i - \hat{\mathbf{X}}_j \| - s \; \big|
$$

| Symbol | Meaning |
|---|---|
| $i, j$ | two corners adjacent on the board grid, horizontally or vertically |
| $s$ | true square size, `SQUARE_SIZE_M` = 24.35 mm |
| $e_{ij}$ | absolute edge-length error for that pair, metres — converted to mm for reporting |

Note that the errors are computed on the *edges between* points, not on the points themselves.
A single point has no checkable error — you never knew where in space the board was supposed
to be. The distance between two neighbours does, because it has to come out at one square.

That gives, per pose and in total:

$$
\underbrace{6 \times 8 = 48}_{\text{horizontal gaps}}
\;+\;
\underbrace{9 \times 5 = 45}_{\text{vertical gaps}}
\;=\; 93 \text{ per pose},
\qquad 93 \times 6 = 558 \text{ measurements}
$$

from $6 \times 54 = 324$ reconstructed points. Pooling all 558, the script prints the mean,
95th percentile, max and standard deviation in millimetres, plus each pose's own mean
separately — so a single bad position, usually the one furthest into a corner of the frame,
shows up rather than being averaged away. Its stated bar is **max < 2 mm and p95 < 1 mm**.

One limitation to keep in view: step 4 forces every point onto the fitted plane, so what is
being measured is whether the calibration reproduces the board's flat geometry at true scale.
It is not a direct test of depth accuracy.

Trust that one, for two reasons: it is in the units the rest of the system runs on — the game
is driven by millimetres, not pixels — and it is measured at poses that took no part in the
fitting, so it tests whether the calibration works in general rather than how well it fitted
its own training photos.

**What the verification cannot catch.** One error slips past both numbers: the square size
itself. If `SQUARE_SIZE_M` says 24.35 mm but the printed squares are really 24.0 mm, then
every reconstructed length, every marker pose, and every position sent to the game is 1.4 %
too large — and nothing anywhere complains. The reprojection error does not move, because a
uniformly rescaled board fits the pixels just as well. The verify error does not move either,
and for a sharper reason: it compares the lengths it reconstructed against the very same
constant that was used to build the board model, so the error sits on both sides of the
comparison and cancels out.

The only defence is external to the software. Measure the printed board with calipers across
ten squares at once and divide by ten, which shrinks your own measurement error by the same
factor — and never trust the nominal size of a pattern that has been through a printer, where
"fit to page" silently rescales by a few percent. This is a systematic error, not noise, so it
never averages away over frames or markers; it survives every stage downstream as a pure scale
factor, right into §8's world coordinates.

**Three quick checks on the numbers themselves:**

- $c_x, c_y$ should sit near the image centre (640, 400 on a 1280×800 sensor). Ours are
  (654, 349) — a plausible manufacturing offset. Far from centre means a bad fit.
- $f_x$ and $f_y$ should be nearly equal, since the pixels are square (§0.3). Ours differ by
  0.3 %.
- The focal length should match the lens you think you have. Working backwards from
  $f \approx 888$, the corner of the image sits about 40° off-axis, making the diagonal field
  of view roughly **81°** — not the **160°** quoted in §0.7 and §1. **This check currently
  fails.** Either the installed lens is much narrower than the documented part, or that 160°
  is a marketing figure for a different sensor size. Worth resolving, because the width of
  this lens is the entire premise of §1.

The output is written to `camera_calib.toml` and is valid only for **that camera with that
lens at that resolution**. Change any of the three and it must be redone — which is why the
file is per-machine and never shared between kits (see `pyscripts/README.md`). The file also
records the board that produced it (`square_size_m`, `board_inner_corners`); check those
against the current constants in `calibrate_camera.py` before trusting a calibration, because
if they disagree the file predates a board change and must be regenerated.

---

## Interlude — calibration is done, so what does tracking do with it?

Calibration answered one half of §0.1's chain. Recall the four arrows:

$$
{}_{\text{world}}\mathbf{X}
\;\xrightarrow{\;\mathbf{R},\, \mathbf{t}\;}\;
{}_{\text{cam}}\mathbf{X}
\;\xrightarrow{\;\div Z\;}\;
(a, b)
\;\xrightarrow{\;\mathbf{D}\;}\;
(x_d, y_d)
\;\xrightarrow{\;\mathbf{K}\;}\;
(u, v)
$$

The right-hand three are now fixed numbers, measured once and stored in `camera_calib.toml`.
**Everything from here on is about the left-hand arrow** — finding $\mathbf{R}$ and
$\mathbf{t}$, the pose of the device, and doing it again for every frame that arrives.

That inversion is only possible *because* the right-hand arrows are pinned down. §6.1 showed a
single pixel gives a ray and no more; the way out was outside information, and there are two
independent pieces of it, both produced offline:

| Produced once, offline | By | Used at run time for |
|---|---|---|
| $\mathbf{K}, \mathbf{D}$ → `camera_calib.toml` | `calibrate_camera.py` (§2) | undistorting the image, and every `solvePnP` |
| marker layout → `board_geometry.json` | `calibrate_board.py` (§7.3) | treating many markers as one rigid object |

Two more things happen once at startup rather than per frame: the undistortion map is built
(§3), and the world origin is locked (§8). Everything else runs on every frame:

$$
\begin{array}{ccccccccc}
\boxed{\text{raw fisheye}} & \longrightarrow & \boxed{\text{undistort}} & \longrightarrow & \boxed{\text{detect}} & \longrightarrow & \boxed{\text{refine}} & \longrightarrow & \boxed{\text{solvePnP}} \\[2pt]
 & & \text{§3} & & \text{§4} & & \text{§5} & & \text{§6} \\[8pt]
 & & & & & & & & \Big\downarrow \\[8pt]
\boxed{\text{cursor}} & \longleftarrow & \boxed{\text{UDP packet}} & \longleftarrow & \boxed{\text{filter}} & \longleftarrow & \boxed{\text{world frame}} & \longleftarrow & \boxed{\text{device pose}} \\[2pt]
\text{§11} & & \text{§10} & & \text{§9} & & \text{§8} & & \text{§7}
\end{array}
$$

Where the offline products enter: $\mathbf{K}, \mathbf{D}$ at **undistort** and again at
**solvePnP**; `board_geometry.json` at **device pose**; the locked origin
$\mathbf{R}_0, \mathbf{t}_0$ at **world frame**.

Two details the diagram leaves out. `process_frame()` also polls the UDP socket each pass for
inbound commands from Godot — `SETUP:` to switch demo mode, `RELOCK` to redo the origin
ritual. And the pose stage is skipped entirely when the detected corners have not moved since
the previous frame (`_pose_is_stable`, `_detection_matches_prev`): reusing the last pose
removes the jitter `solvePnP` would otherwise produce by returning slightly different answers
for identical input.

The sections that follow walk the "every frame" column in order.

---

## 3. Image undistortion — straightening the fisheye

### 3.1 What this stage produces

Undistortion is picture in, picture out. Nothing more.

The raw frame is a grid of $1280 \times 800$ brightness values. This stage builds a
**second, separate** grid of $1280 \times 800$ brightness values. The entire operation is:
walk through the million-odd cells of the new grid one at a time and, for each one, copy a
brightness value out of the old grid. No markers are found here, no geometry is computed,
nothing 3D happens. Brightness values are rearranged into a new picture, and that picture
is handed to §4 as though it had come from a perfect pinhole camera.

The only question is therefore: **for each cell of the new image, which cell of the old
image do we copy from?**

`main.py` answers that once, at startup, and stores the answers in a lookup table:

```python
self.map1, self.map2 = cv2.fisheye.initUndistortRectifyMap(
    K, D, np.eye(3), K, frame_size, cv2.CV_16SC2
)
```

Two arrays, each the size of the output image, holding between them one source coordinate
per output pixel. Together they are the instruction sheet: *to fill new pixel
$(1200, 750)$, read the raw frame at $(1201.56,\; 751.15)$.*

Throughout this section, **primed symbols belong to the new (corrected) image and unprimed
symbols to the raw (distorted) one.**

**The arguments.** The signature is
`cv2.fisheye.initUndistortRectifyMap(K, D, R, P, size, m1type)`:

| Position | Passed here | Role |
|---|---|---|
| 1 — `K` | `camera_matrix` | intrinsics of the **raw** camera; describes how the distorted frame was formed. Used at the end of Step 4 to return to raw pixel coordinates. |
| 2 — `D` | `dist_coeffs` | the four fisheye coefficients $k_1 \ldots k_4$ of Step 3 |
| 3 — `R` | `np.eye(3)` | rectification rotation applied between the output frame and the camera frame. Identity here — no rotation. Non-identity is used for stereo rectification, which this pipeline does not do (§7.4 fuses poses, not images). |
| 4 — `P` | `camera_matrix` | intrinsics of the **output** image — what the corrected picture should pretend to be. Used to undo Step 1. |
| 5 — `size` | `(1280, 800)` | dimensions of the output image, and hence of the maps |
| 6 — `m1type` | `cv2.CV_16SC2` | storage format of the maps (below) |

**Why $\mathbf{K}$ appears twice.** Arguments 1 and 4 are different roles that here happen
to receive the same value. Argument 1 is *the camera you have*; argument 4 is *the camera
you want the output to behave like*. They need not match — passing a shorter focal length
in position 4 would squeeze more of the wide field into the output frame, at the cost of
resolution in the middle.

Passing $\mathbf{K}$ in both says: **give the corrected image exactly the same focal length
and principal point as the raw one.** Two consequences worth holding on to:

- Step 1 and Step 4's closing move use the *same* matrix, so they cancel exactly for a
  ray on the optical axis, and nearly cancel near it. This is why §3.4's worked example
  barely moves: $1200 \to 1201.56$.
- Every downstream `solvePnP` call passes `self.camera_matrix` — that is, $\mathbf{K}$ —
  together with `np.zeros(5)`. That is correct **only because** argument 4 was $\mathbf{K}$.
  Change it and the intrinsics used by every pose solve become wrong, silently, with
  nothing in the pipeline to complain.

**Why the map is rebuilt at every start** rather than saved alongside the calibration.
It is genuinely fixed for a given camera, so the question is fair. Three reasons:

- **Size.** In `CV_16SC2`, `map1` stores two `int16` per pixel and `map2` one `uint16`, so
  $1280 \times 800$ costs $4.10 + 2.05 \approx 6.1$ MB. As JSON text it would be several
  times that, and slow to parse.
- **Nothing is saved.** Building it is roughly one million evaluations of an arctangent and
  a degree-9 polynomial — order tens to hundreds of milliseconds, once, though this has not
  been measured on the Pi. Reading 6 MB off an SD card is plausibly the same order or
  worse, so the trade is compute for I/O at no clear gain. If startup latency ever matters,
  time it before assuming the cache would help.
- **It cannot go stale.** The map is *derived* from $\mathbf{K}$, $\mathbf{D}$, the output
  intrinsics and the frame size. Caching it would create a second artefact able to disagree
  silently with `camera_calib.toml`; deriving it at startup leaves one source of truth.

**The storage format.** `CV_16SC2` is OpenCV's fixed-point map format: `map1` holds the
integer part of the source pixel as a pair of `int16`, and `map2` holds an index into
OpenCV's interpolation weight table for the fractional part. It quantises the source
coordinate to $1/32$ px — an order of magnitude below §5's $\pm 0.1$ px corner-refinement
floor, so it costs nothing that reaches the output — while being both smaller and faster
to sample than the float alternative, `CV_32FC1`.

### 3.2 The four steps that fill one table entry

Fix one output pixel $(u', v')$ and follow it through. Everything below happens once per
output pixel, at startup, and never again.

#### Step 1 — strip the camera off

The new image is *defined* as the picture a perfect pinhole camera with intrinsics
$\mathbf{K}$ would have produced. So the coordinates $(u', v')$ are not merely a location
in an array; they carry a claim about a direction in space. §0.4 gave the forward version
of that claim, $u = f_x (X/Z) + c_x$. Run it backwards:

$$
x' = \frac{u' - c_x}{f_x}, \qquad y' = \frac{v' - c_y}{f_y}
$$

**These are dimensionless.** $u'$, $c_x$ and $f_x$ are all in pixels — recall $f_x = f/s_x$
from §0.3, metres divided by metres-per-pixel — so the quotient carries no units at all.
That is worth stating explicitly because §0.3's $x_{\text{sensor}}$ *was* a physical
distance on the chip in metres, and the two are easy to confuse. This one is not a distance
on any physical surface.

What it is instead: $x' = X/Z$ and $y' = Y/Z$, the point's position on an imaginary image
plane one unit in front of the camera. The standard name is **normalised image
coordinates**, and the name says what has happened — the camera's own constants have been
divided out, leaving a description of the ray alone.

#### Step 2 — convert position into ray angle

§1's entire description of the lens is phrased in terms of $\theta$, the angle between the
incoming ray and the optical axis. The polynomial bends **angles**, not pixel positions.
So the next thing needed from $(x', y')$ is that angle.

Picture the situation at a single depth. Everything at depth $Z$ lies on a flat plane
perpendicular to the optical axis; the axis pierces that plane at one point. The ray's
distance from that point, measured in the plane, is its total off-axis offset — and because
the ray is displaced in $X$ **and** in $Y$ at once, that offset is the hypotenuse of the
two:

$$
\text{offset in the plane} = \sqrt{X^2 + Y^2}
$$

$$
r' = \frac{\sqrt{X^2 + Y^2}}{Z} = \sqrt{x'^2 + y'^2}
$$

The first expression is metres over metres; the second is built from the dimensionless
quantities of Step 1. They are the same number, and it is dimensionless either way.

The triangle with adjacent side $Z$ and opposite side $\sqrt{X^2+Y^2}$ then gives the angle
directly:

$$
\tan\theta = r'
\qquad\Longrightarrow\qquad
\theta = \arctan r'
$$

*A worked instance.* A point 2 m down the axis, sitting 0.3 m right of the axis and 0.4 m
below it, is $\sqrt{0.3^2 + 0.4^2} = 0.5$ m off-axis. Then $r' = 0.5/2 = 0.25$ and
$\theta = \arctan(0.25) = 0.2450$ rad $= 14.0°$.

**A common slip.** $\tan\theta = X/Z$ is true only for a ray lying in the $XZ$ plane, with
$Y = 0$. The general ray is off-axis in both directions simultaneously, and the square root
is what accounts for that.

#### Step 3 — ask the lens where it actually puts that ray

Two competing answers to "at what radius does a ray at angle $\theta$ land?":

| Model | Landing radius, normalised units | Landing radius, pixels |
|---|---|---|
| pinhole | $\tan\theta \;(= r')$ | $f\tan\theta$ |
| ideal fisheye | $\theta$ | $f\theta$ |
| this lens | $\theta_d$ (below) | $f\theta_d$ |

The middle row uses **an angle as a radius**, which looks like a category error until you
see where it comes from. An ideal fisheye is *defined* by $r = f\theta$ in pixels; divide
through by $f$ to reach normalised units and the radius is $\theta$ itself. That convention
is precisely what lets the model survive to 90°, where $\tan\theta$ diverges and no
rectilinear lens can put the ray on a finite sensor at all (§0.7).

Near the axis the first two rows agree closely. At $\theta = 0.2450$ rad,
$\tan\theta = 0.2500$ against $\theta = 0.2450$ — about 2 % apart, with the pinhole radius
the larger of the two. $\tan\theta > \theta$ for every $\theta$ in $(0, \pi/2)$, and the gap
grows fast: 10 % at 30°, 65 % at 60° (§0.7's table).

No physical lens follows the ideal row exactly, so calibration (§2) fits the residual as a
polynomial:

$$
\theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right)
$$

$\theta_d$ is the normalised radius at which *this particular* lens puts a ray arriving at
angle $\theta$. Setting every $k_i = 0$ collapses it to $\theta_d = \theta$, the ideal
fisheye — the coefficients are a correction to that row, not a model in their own right.

#### Step 4 — rescale, and put the camera back on

Two quantities are now in hand: a **direction**, $(x', y')$, currently at radius $r'$; and
the radius the real lens assigns to that direction, $\theta_d$. Scale the point from one
radius to the other:

$$
s = \frac{\theta_d}{r'}, \qquad x_d = s\,x', \qquad y_d = s\,y'
$$

**Why a single scalar suffices.** A lens is a stack of circular elements centred on the
optical axis, so it is **radially symmetric**: the amount by which it bends a ray can
depend only on how far off-axis the ray arrives, never on which way round the axis it
arrives from. A ray at 30° from the left is bent exactly as much as one at 30° from above.
Consequently the lens can only slide a point along its own radius — it can never swing it
sideways — so direction is preserved, distance changes, and that is one number's worth of
freedom.

(This is not a statement about pixel geometry. Whether the sensor's pixels are square is a
separate matter, handled entirely by $f_x$ against $f_y$ inside $\mathbf{K}$, and covered
in §0.3. The OV9281's pixels are square.)

The same symmetry appears in the algebra of Step 3: the polynomial contains only **even**
powers of $\theta$, because odd powers would change sign with $\theta$ and break exactly
this. One physical fact, surfacing in two places.

$(x_d, y_d)$ are normalised coordinates in the **raw** image. The only thing between them
and a pixel address is $\mathbf{K}$, which Step 1 removed, so put it back — Step 4 is
literally the inverse of Step 1:

$$
u = f_x\,x_d + c_x, \qquad v = f_y\,y_d + c_y
$$

and that pair is the table entry for this output pixel:

$$
\operatorname{map}[v'][u'] = (u,\; v)
$$

(Written as a single conceptual entry. In the `CV_16SC2` format actually used, the integer
part of $(u, v)$ lives in `map1` and the fractional part is encoded as an interpolation-table
index in `map2` — see §3.1. The split is a storage detail; the content is this pair.)

At $r' = 0$ the ratio $\theta_d/r'$ is taken as its limit, 1 — the centre pixel maps to
itself.

### 3.3 The four steps as one equation

The four steps compose into a single expression. Steps 1 and 4 are matrix multiplications;
Steps 2 and 3 collapse into the scalar $s$:

$$
\boxed{\;
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
=
\mathbf{K}\,\mathbf{S}\,\mathbf{K}^{-1}
\begin{bmatrix} u' \\ v' \\ 1 \end{bmatrix}
\;}
\qquad
\mathbf{S} = \begin{bmatrix} s & 0 & 0 \\ 0 & s & 0 \\ 0 & 0 & 1 \end{bmatrix}
$$

Read right to left, it is the four steps in order: $\mathbf{K}^{-1}$ is Step 1,
$\mathbf{S}$ is Step 4's rescale (carrying Steps 2 and 3 inside $s$), and $\mathbf{K}$ is
Step 4's closing move. It is §1.1's forward model with $\mathbf{K}$ wrapped around it — the
same $\mathbf{S}$, now conjugated.

| Symbol | Type | Units | Definition |
|---|---|---|---|
| $(u', v')$ | scalar pair, integer | pixels | index into the corrected output image; the loop variable |
| $(x', y')$ | scalar pair | dimensionless | $\left((u'-c_x)/f_x,\; (v'-c_y)/f_y\right)$ — normalised image coordinates, equal to $(X/Z,\, Y/Z)$ |
| $r'$ | scalar, $\ge 0$ | dimensionless | $\sqrt{x'^2 + y'^2}$; equals $\tan\theta$ |
| $\theta$ | scalar, $[0, \pi/2)$ | radians | $\arctan r'$; angle between the incoming ray and the optical axis |
| $\theta_d$ | scalar, $\ge 0$ | radians, used as a normalised radius | $\theta(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8)$ |
| $s$ | scalar | dimensionless | $\theta_d / r'$; radial scale factor, **a different value at every output pixel** |
| $\mathbf{S}$ | $3\times3$ | dimensionless | $\operatorname{diag}(s, s, 1)$; the radial warp of §1.1 in normalised coordinates |
| $(x_d, y_d)$ | scalar pair | dimensionless | $(s\,x',\; s\,y')$ — normalised coordinates in the raw, distorted image |
| $\mathbf{K}$ | $3\times3$ | pixels | intrinsics, $\operatorname{diag}$-plus-offset form of §0.6; constant for the run |
| $\mathbf{K}^{-1}$ | $3\times3$ | pixels$^{-1}$ | maps pixel coordinates to normalised coordinates |
| $(u, v)$ | scalar pair, real-valued | pixels | source coordinate in the raw fisheye image; generally non-integer |

**Why it cannot be collapsed into one matrix.** $\mathbf{S}$ is not constant. $s$ depends
on $r'$, which depends on which output pixel is being filled, so every pixel gets its own
$\mathbf{S}$ and the product $\mathbf{K}\mathbf{S}\mathbf{K}^{-1}$ can never be computed
once and reused. Filling in $s$ takes three scalar operations that are not matrix algebra
at all — a square root, an arctangent, and a polynomial:

$$
x' = \frac{u' - c_x}{f_x}, \qquad y' = \frac{v' - c_y}{f_y}, \qquad r' = \sqrt{x'^2 + y'^2}
$$

$$
\theta = \arctan r', \qquad
\theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right),
\qquad s = \frac{\theta_d}{r'}
$$

That is the same split as §1.1: matrices for the linear parts, scalar functions for the one
piece that genuinely is not linear.

### 3.4 Worked example — one entry of the table

Take the output pixel $(u', v') = (1200, 750)$, using this camera's fitted values:

$$
f_x = 887.26, \quad f_y = 889.98, \quad c_x = 654.01, \quad c_y = 348.84
$$

$$
k_1 = 0.3303, \quad k_2 = 0.5552, \quad k_3 = -1.4004, \quad k_4 = 1.2545
$$

*Step 1 — strip off $\mathbf{K}$.* Subtract the principal point, divide by the focal length:

$$
x' = \frac{1200 - 654.01}{887.26} = 0.615370,
\qquad
y' = \frac{750 - 348.84}{889.98} = 0.450751
$$

*Step 2a — how far from the centre:*

$$
r' = \sqrt{0.615370^2 + 0.450751^2} = \sqrt{0.378680 + 0.203176} = 0.762795
$$

*Step 2b — the ray angle that corresponds to:*

$$
\theta = \arctan(0.762795) = 0.651644 \text{ rad} = 37.33^\circ
$$

*Step 3 — what the lens does to that angle.* The powers of $\theta$ are

$$
\theta^2 = 0.424640, \quad \theta^4 = 0.180319, \quad \theta^6 = 0.076578, \quad \theta^8 = 0.032521
$$

| Term | Value |
|---|---|
| $k_1 \theta^2$ | $+0.140258$ |
| $k_2 \theta^4$ | $+0.100113$ |
| $k_3 \theta^6$ | $-0.107240$ |
| $k_4 \theta^8$ | $+0.040798$ |
| **bracket total** | $\mathbf{1.173929}$ |

$$
\theta_d = \theta \times 1.173929 = 0.651644 \times 1.173929 = 0.764975
$$

*Step 4a — the scale factor:*

$$
s = \frac{\theta_d}{r'} = \frac{0.764975}{0.762795} = 1.002858
$$

*Step 4b — apply it:*

$$
x_d = 1.002858 \times 0.615370 = 0.617129,
\qquad
y_d = 1.002858 \times 0.450751 = 0.452039
$$

*Step 4c — put $\mathbf{K}$ back:*

$$
u = 887.26 \times 0.617129 + 654.01 = 1201.56,
\qquad
v = 889.98 \times 0.452039 + 348.84 = 751.15
$$

So this pixel's entry in the table is

$$
\operatorname{map}[750][1200] = (1201.56,\; 751.15)
$$

meaning: *to fill output pixel $(1200, 750)$, sample the raw frame at $(1201.56,\, 751.15)$.*
Note how small the correction is here — about 1.6 px — which is consistent with the
near-zero distortion this particular calibration describes (see the field-of-view check in
§2).

### 3.5 The table describes the camera, not the scene

Only $\mathbf{K}$ and $\mathbf{D}$ appear anywhere in §3.4. No property of the scene enters
at any step. Three consequences:

- Pixel $(1200, 750)$ pulls from $(1201.56, 751.15)$ on **every frame for the life of the
  process**, whatever happens to be in view. Moving the device changes *which* pixel it
  lands on — never what that pixel's correction is. This is why the table is built once at
  startup rather than per frame.
- It does not depend on depth either. The warp acts on the ratios $X/Z$ and $Y/Z$, so two
  points at different distances along one line of sight reach the same pixel and take the
  same correction.
- It is invalidated only by changing the camera, the lens, or the resolution — the same
  three things that invalidate `camera_calib.toml` (§2).

### 3.6 Why the map is built output-first

Every step in §3.4 is a *forward* evaluation: the polynomial is applied, never inverted.
That is deliberate, and it is the reason the loop runs over output pixels rather than input
pixels.

Going the other way — starting from a raw pixel and asking where it should move to — would
require solving

$$
\theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right)
$$

for $\theta$ given $\theta_d$. That is a degree-9 polynomial with no closed-form inverse, so
it would mean a numerical root-find **per pixel**. By starting from the output grid and
asking "where did this pixel come from?", the awkward inversion never has to happen at all.

It also guarantees every output pixel receives exactly one value. Pushing source pixels
forward into the output would leave gaps where the warp stretches the image and collisions
where it compresses, and both would then need patching.

This is the standard trick for image warping in general: **iterate over the destination,
not the source.**

### 3.7 Sampling — bilinear interpolation

At runtime, one line does the work:

```python
frame0 = cv2.remap(frame0, self.map1, self.map2, interpolation=cv2.INTER_LINEAR)
```

`remap` looks up each output pixel's source coordinate in the table and samples the raw
image there. But those coordinates are almost never whole numbers — §3.4 asked for
$(1201.56,\, 751.15)$, and there is no pixel at $0.56$ of the way across. So the value must
be **interpolated** from the neighbours that do exist.

Let $(u_0, v_0)$ be the integer pixel below-left of the requested point and let

$$
\alpha = u - u_0, \qquad \beta = v - v_0 \qquad (0 \le \alpha, \beta < 1)
$$

be the fractional parts. Interpolate linearly along $u$ on each of the two rows, then
linearly between those two results along $v$:

$$
I(u,v) =
(1-\beta)\Big[ (1-\alpha) I[u_0, v_0] + \alpha I[u_0{+}1, v_0] \Big]
+ \beta\Big[ (1-\alpha) I[u_0, v_0{+}1] + \alpha I[u_0{+}1, v_0{+}1] \Big]
$$

Four pixels, four multiply-adds, and the four weights sum to 1 — so a flat region keeps its
brightness exactly, which is what stops interpolation from manufacturing edges that were
not in the scene.

**Why not bicubic.** `INTER_CUBIC` fits a cubic through a $4 \times 4$ neighbourhood, keeps
sharp edges crisper, and costs roughly twice as much. It was rejected for a specific reason
recorded in the code:

```python
# INTER_LINEAR: ~half the cost of INTER_CUBIC; corner sub-pixel accuracy
# comes from the detector's corner refinement, not the resampling kernel.
```

That is the right call, and §5 is why. Sub-pixel corner accuracy is produced by fitting
lines to ~85 contour pixels per side, which averages over exactly the kind of small,
zero-mean resampling error that bilinear interpolation introduces. Paying twice the cost
per frame to sharpen an image whose corners will be re-measured by least squares anyway
buys nothing — and on a Pi that is also rendering a game, half the remap cost is worth
having.

**Result:** an image in which straight lines in the world are straight in the image. It
behaves like a pinhole camera with intrinsics $\mathbf{K}$ and *zero* distortion — which is
why every later `solvePnP` call passes `np.zeros(5)` for the distortion coefficients.

---

## 4. Marker detection — from a clean image to four corners

§3 handed over an image that behaves like a perfect pinhole camera. Every equation from
here on can use §0's simple form and forget the lens entirely.

But an image is still just a grid of brightness numbers. Nothing in it says "there is a
marker at these pixels." This section is where the pipeline stops doing geometry and starts
doing *search* — and where, for the first and only time, the maths is mostly decisions
rather than equations.

### 4.1 Why square black-and-white tags at all

Before the algorithm, the design problem it solves. The tracker needs a target on the
device that satisfies three things at once:

1. **Findable** — locatable without already knowing where it is, under whatever lighting
   the clinic room has.
2. **Identifiable** — the device carries eight of them, and confusing marker 12 with
   marker 20 would put the grip point on the wrong side of the handle.
3. **Anchored** — it must supply points whose 3D position *on the device* is known
   exactly, because §6 needs known 3D ↔ observed 2D pairs and nothing else will do.

A square with a thick black border and a coded interior hits all three. The border is the
strongest possible edge for a thresholding step; the interior encodes identity; and the
four corners are points whose marker-frame coordinates are exact by construction —
$(\pm L/2, \pm L/2, 0)$ for a printed square of side $L$.

**Why corners rather than the centre or the edges.** This is worth being precise about,
because it is the reason the whole pipeline is built around four points.

- An **edge** constrains position only *across* itself. Slide a point along a straight
  edge and the image is unchanged, so an edge pixel tells you one number, not two. (This
  is the aperture problem — the same effect that makes a moving straight bar's velocity
  ambiguous when seen through a small hole.)
- A **corner** is the intersection of two edges running in different directions, so it is
  pinned in both image directions at once. It is the most precisely localisable feature a
  black-and-white shape can offer.
- The **centre** of the marker is precise too, but it is *one* point — and §6.1 already
  showed that one point gives one ray and no depth. Four corners at known separations are
  what break that.

### 4.2 Which dictionary — and what "36h11" means

```python
dictionary = aruco.getPredefinedDictionary(aruco.DICT_APRILTAG_36h11)
detector   = aruco.ArucoDetector(dictionary, params)
```

Two different things are being combined here, and the name of the doc reflects the first:

- The **codebook** is AprilTag's `36h11` family (developed by Edwin Olson's group at
  Michigan). It defines which bit patterns are legal marker IDs.
- The **detector** is OpenCV's ArUco detector. It does the image work — thresholding,
  contours, quads — and then asks the codebook to identify what it found.

So the tags on the device are AprilTags; the code that finds them is the ArUco pipeline.
Nothing is inconsistent about that: the detector is agnostic about which dictionary it is
handed.

**Decoding the name.** `36h11` means **36 data bits**, arranged as a $6 \times 6$ grid,
with a guaranteed **minimum Hamming distance of 11** between any two codes in the family.
Those two numbers are the whole design:

- 36 bits could in principle label $2^{36}$ markers. The family keeps only 587 of them —
  the rest are thrown away precisely so that the survivors are far apart.
- "Far apart" is what buys the error correction in §4.7 and, more importantly, what makes
  a random piece of clutter in the image extremely unlikely to decode as a valid ID.

That trade — throwing away almost all the codes to make the few that remain unmistakable
— is the same reasoning behind error-correcting codes in a communication link. A larger
minimum distance costs you rate and buys you reliability.

### 4.3 Adaptive thresholding — turning grey into black and white

The first stage converts the greyscale frame into a strictly black-or-white one, because
everything downstream works on regions and boundaries, not shades.

**Why not one threshold for the whole image.** Model what the sensor records at a pixel as

$$
I(u,v) \;=\; R(u,v) \cdot L(u,v)
$$

where $R$ is the **reflectance** of the surface (the thing you care about: ~0.05 for the
printed black, ~0.85 for the white) and $L$ is the **illumination** falling on it. In a
room with a window on one side, $L$ might be four times larger at one edge of the frame
than the other. Then white paper in the dim corner,

$$
0.85 \times L_{\text{dim}},
$$

can easily be *darker* than black ink in the bright corner,

$$
0.05 \times L_{\text{bright}},
$$

and no single global threshold can separate them. The image is not badly exposed; the
question is badly posed.

**The fix.** Compare each pixel against its own neighbourhood instead of against a global
constant:

$$
T(u, v) \;=\; \frac{1}{w^2} \sum_{(i, j) \,\in\, \text{window}} I(i, j) \;-\; C
$$

and call the pixel black if $I(u,v) < T(u,v)$.

Why this works falls straight out of the model. Over a window small enough that $L$ is
essentially constant at $L_0$, the local mean is $L_0 \cdot \bar{R}$, so the comparison
$I < T$ becomes

$$
R(u,v) \, L_0 \;<\; \bar{R} \, L_0 - C
\qquad\Longleftrightarrow\qquad
R(u,v) \;<\; \bar{R} - \frac{C}{L_0}
$$

The illumination **divides out**. What is left is a comparison of reflectances — exactly
the quantity that distinguishes ink from paper. The lighting has been cancelled rather
than fought.

**Choosing the window size $w$.** The derivation above shows the two-sided constraint:

- $w$ must be **small enough** that $L$ really is constant across it, otherwise the
  cancellation is only approximate.
- $w$ must be **large enough** to contain both ink and paper. A window sitting entirely
  inside a thick black border has $\bar{R} \approx R$, so the comparison reduces to
  $0 < -C/L_0$, which is false everywhere — the interior of a large black region comes out
  uniformly white. The window must be wider than the widest all-black feature you need to
  survive.

OpenCV's default hedges by sweeping three window sizes (3, 13, 23) and attempting
detection at each. `main.py` replaces that with a single pass:

```python
params.adaptiveThreshWinSizeMin  = 15
params.adaptiveThreshWinSizeMax  = 15
params.adaptiveThreshWinSizeStep = 1
```

That is legitimate here only because the geometry is pinned down: the camera is fixed, the
device moves in a bounded workspace, so the marker's apparent size lives in a known narrow
range. The debug print exists to confirm exactly this —

```
marker side: avg 88.4 px  (n=3 markers)
```

— and it is the number to check before trusting the single-window shortcut. The saving is
real: roughly one third of the thresholding cost, on a Pi that also has a game to render.

`params.useAruco3Detection = True` adds a second speed idea from the same direction: run
the candidate search on a downscaled copy of the image, where there are far fewer pixels to
threshold and trace, then return to the full-resolution frame only for the corners of the
candidates that survived. Accuracy is unaffected because accuracy comes from §5, which
always works at full resolution.

### 4.4 Contour extraction

The binary image is now walked to find the boundary of every connected black region
(OpenCV uses the Suzuki–Abe border-following algorithm). Each contour comes back as an
ordered list of integer pixel coordinates forming a closed loop.

There is no equation here, and one practical consequence worth carrying forward: contours
are lists of *many* pixels along each side of a marker — typically 80–90 of them per side
at our working distance. §5 will use every one of them.

### 4.5 Quad filtering — Douglas–Peucker

Most contours are not markers. They are cable edges, table joins, shadow boundaries,
knuckles. The filter that survives them is simple: a marker's outline, once simplified,
must be exactly four straight sides.

**The simplification.** `approxPolyDP` implements the Douglas–Peucker algorithm, which is
worth stating in full because the doc previously just named it:

1. Take the two endpoints of the contour segment and draw the straight chord between them.
2. Find the contour point $\mathbf{p}^\ast$ with the greatest perpendicular distance from
   that chord. For a chord from $\mathbf{a}$ to $\mathbf{b}$, the distance of a point
   $\mathbf{p}$ is

$$
d(\mathbf{p}) \;=\; \frac{\left| (\mathbf{b} - \mathbf{a}) \times (\mathbf{p} - \mathbf{a}) \right|}{\|\mathbf{b} - \mathbf{a}\|}
$$

   where the 2D cross product is the scalar
   $(b_x - a_x)(p_y - a_y) - (b_y - a_y)(p_x - a_x)$.
3. If $d(\mathbf{p}^\ast) \le \epsilon$, **discard every interior point** — the whole
   stretch is within tolerance of a straight line.
4. Otherwise **keep** $\mathbf{p}^\ast$ as a vertex and recurse on the two halves
   $[\mathbf{a}, \mathbf{p}^\ast]$ and $[\mathbf{p}^\ast, \mathbf{b}]$.

The recursion terminates because each call strictly shortens the segment. What survives is
the smallest set of vertices that reproduces the contour to within $\epsilon$ everywhere.

**Why $\epsilon$ is a fraction of the perimeter, not a fixed pixel count:**

$$
\epsilon \;=\; 0.05 \cdot \text{perimeter}
$$

A marker 300 px across when the hand is near the camera and 60 px across when it is far
away is the *same square*, and must simplify to four vertices in both cases. Tying
$\epsilon$ to the contour's own size makes the tolerance scale-invariant: 5 % of the
perimeter is 5 % whether the marker is near or far. A fixed 3 px tolerance would either
over-simplify the small one or under-simplify the large one.

**Worked example.** Take a contour running along the bottom edge of a marker from
$\mathbf{a} = (100, 400)$ to $\mathbf{b} = (200, 400)$, with a thresholding artefact
bulging one pixel out at $\mathbf{p} = (150, 403)$. The chord is horizontal with length
100, so

$$
d(\mathbf{p}) = \frac{|(100)(3) - (0)(50)|}{100} = 3 \text{ px}
$$

If this side belongs to a marker of perimeter 400 px, then $\epsilon = 20$ px and
$3 \le 20$: the bulge is discarded and the side collapses to a clean two-vertex line. A
genuine corner, sitting 50–100 px off its chord, survives easily. The tolerance is
generously wide because §5 will re-measure the corners properly anyway — this stage only
has to answer *"is this shape a quadrilateral?"*, not *"where exactly are its corners?"*

**The surviving tests.** A candidate is kept only if the simplified polygon has exactly
4 vertices, is **convex**, and exceeds a minimum area. Convexity is checked by walking the
four edges and requiring the 2D cross product of consecutive edge vectors to keep the same
sign all the way round — a sign flip means the outline turns back on itself, which a
square photographed through *any* pinhole camera can never do.

### 4.6 Perspective rectification — the homography

Each surviving quadrilateral is a distorted view of a square. To read the bits inside, it
must first be un-distorted back into a square. **This subsection is the most important
piece of maths in §4, because the same object comes back in §6 as the pose solver itself.**

**Why a marker's image is governed by a $3\times3$ matrix.** Take §0.6's projection and
feed it a point on the marker. The marker is *flat*, so in the marker's own frame every
point has $Z = 0$:

$$
\lambda \begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
= \mathbf{K}\left( \mathbf{R} \begin{bmatrix} x \\ y \\ 0 \end{bmatrix} + \mathbf{t} \right)
$$

Write $\mathbf{R}$ by its columns, $\mathbf{R} = [\,\mathbf{r}_1 \mid \mathbf{r}_2 \mid \mathbf{r}_3\,]$.
Then $\mathbf{R}(x, y, 0)^\top = x\,\mathbf{r}_1 + y\,\mathbf{r}_2 + 0 \cdot \mathbf{r}_3$
— **the third column drops out entirely**, because there is no third coordinate to
multiply it. So

$$
\lambda \begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
= \mathbf{K}\left( x\,\mathbf{r}_1 + y\,\mathbf{r}_2 + \mathbf{t} \right)
= \underbrace{\mathbf{K}\,[\,\mathbf{r}_1 \mid \mathbf{r}_2 \mid \mathbf{t}\,]}_{\textstyle \mathbf{H}}
\begin{bmatrix} x \\ y \\ 1 \end{bmatrix}
$$

$\mathbf{H}$ is a $3 \times 3$ matrix called the **homography**. What has just been proved
is a strong statement: *any* flat object, viewed by *any* pinhole camera, from *any* pose,
maps to the image through a single $3 \times 3$ matrix. Flatness is the whole reason — the
$Z = 0$ that killed $\mathbf{r}_3$.

**How many numbers does it really have?** $\mathbf{H}$ has 9 entries, but it appears inside
an equality-up-to-scale (the $\lambda$, §0.6). Multiplying every entry by 5 multiplies
$\lambda$ by 5 and leaves $(u, v)$ untouched. So one degree of freedom is meaningless and
$\mathbf{H}$ carries **8** — conventionally fixed by setting $h_{33} = 1$.

**Solving for it from four corners.** Expand the matrix equation into scalars and divide
out $\lambda$ by taking ratios against the third row:

$$
u = \frac{h_{11}x + h_{12}y + h_{13}}{h_{31}x + h_{32}y + h_{33}},
\qquad
v = \frac{h_{21}x + h_{22}y + h_{23}}{h_{31}x + h_{32}y + h_{33}}
$$

These look hopeless — the unknowns are in the denominator. But multiply through by the
denominator and every $h$ appears to the first power only:

$$
h_{11}x + h_{12}y + h_{13} - u\,h_{31}x - u\,h_{32}y - u\,h_{33} = 0
$$
$$
h_{21}x + h_{22}y + h_{23} - v\,h_{31}x - v\,h_{32}y - v\,h_{33} = 0
$$

**Two linear equations per corner.** This is the same trick as §0.6's homogeneous
coordinates, used again: cross-multiplying moves a division out of the unknowns and leaves
a linear system. Four corners give $4 \times 2 = 8$ equations for 8 unknowns — exactly
determined, no least squares needed. That is why the detector wants exactly four vertices
and why `cv2.getPerspectiveTransform` takes exactly four point pairs.

**Concretely, for one corner.** Marker-frame corner $(x, y) = (0, 0)$ observed at pixel
$(u, v) = (612, 344)$, with $h_{33}$ fixed to 1, contributes the two rows

$$
h_{13} = 612, \qquad h_{23} = 344
$$

(every term carrying $x$ or $y$ vanishes). The other three corners fill in the remaining
six rows, and an $8 \times 8$ solve finishes it.

**Then the resampling.** With $\mathbf{H}$ known, `warpPerspective` fills a small canonical
image by running the map backwards — for each output cell, ask which input pixel it came
from — the same output-first strategy, and for the same reason, as §3's undistortion map.
For `36h11` the canonical view is $8 \times 8$ cells (6 data cells plus a one-cell black
border all round) at `perspectiveRemovePixelPerCell = 4` pixels per cell, so a $32 \times 32$
image.

**Hold on to this.** $\mathbf{H} = \mathbf{K}[\,\mathbf{r}_1 \mid \mathbf{r}_2 \mid \mathbf{t}\,]$
has $\mathbf{R}$ and $\mathbf{t}$ sitting inside it — the very quantities the tracker is
trying to find. The detector computes $\mathbf{H}$ only to read the bits and then throws it
away. §6.3 computes the same object and **decodes it into a pose** instead. The detection
stage and the pose stage are the same equation read in two directions.

### 4.7 Bit decoding

Divide the canonical view into its $8 \times 8$ cells and average the pixels inside each
one, trimming a margin from every cell edge before averaging
(`perspectiveRemoveIgnoredMarginPerCell = 0.13`, so only the central 74 % of each cell
counts). The margin matters: cell boundaries are exactly where the resampling is least
trustworthy and where a fraction of a pixel of homography error does the most damage.
Threshold each cell mean → a bit.

The 28 border cells must all come out black. A candidate that fails this is rejected
immediately, before any dictionary lookup — cheap, and it kills most surviving clutter.
The 36 interior cells become the observed code word.

### 4.8 Dictionary lookup, error correction, and orientation

**Hamming distance** between two bit strings is simply the number of positions where they
differ. The `36h11` family guarantees that any two of its 587 valid codes differ in at
least 11 of the 36 positions.

**Why that corrects up to 5 errors.** Suppose the true marker's code is $c$, and glare,
blur, or a smudge flipped $e$ of the observed bits, giving $c'$ with $d(c, c') = e$. Take
any *other* valid code $c''$. By the triangle inequality for Hamming distance,

$$
d(c', c'') \;\ge\; d(c, c'') - d(c, c') \;\ge\; 11 - e
$$

So $c$ is the strictly nearest valid code to what was observed whenever

$$
e \;<\; 11 - e
\qquad\Longleftrightarrow\qquad
e \;<\; 5.5
\qquad\Longleftrightarrow\qquad
e \;\le\; 5
$$

Up to 5 flipped bits out of 36 — one bit in seven — and the ID is still recovered
*uniquely*, not merely plausibly. The general statement is that a minimum distance $d$
corrects $\lfloor (d-1)/2 \rfloor$ errors; here $\lfloor 10/2 \rfloor = 5$. The detector
reports the ID when the nearest valid code is within that radius and rejects the candidate
otherwise.

**Orientation falls out of the same lookup, and this matters more than it looks.** The
detector does not know which side of the quadrilateral is the marker's "top". So it tests
the observed 36 bits in all four 90° rotations against the dictionary. Only one rotation
matches a valid code — the family is built so that no code is a rotation of another — and
that tells you which detected vertex is the marker's top-left.

This is what makes the corner order **consistent**, and §6 depends on it completely.
`solvePnP` pairs object point $k$ with image point $k$; `board.py` lists the object points
in ArUco's detection order:

```python
def marker_object_points(length):
    h = length / 2
    return np.array([[-h,  h, 0],     # top-left
                     [ h,  h, 0],     # top-right
                     [ h, -h, 0],     # bottom-right
                     [-h, -h, 0]])    # bottom-left
```

Get that order wrong and `solvePnP` still returns a pose, confidently, and it is wrong by
a 90° rotation.

### 4.9 What comes out

```python
corners, ids, _ = self.detector.detectMarkers(frame0)
```

`ids` is an $(N, 1)$ array of integers; `corners` is a tuple of $N$ arrays of shape
$(1, 4, 2)$, in the order TL, TR, BR, BL. Corner accuracy at this point is about
$\pm 1$ pixel — they came from a polygon fitted to integer contour points on a
thresholded image, and nothing so far has done better than whole pixels.

The next section explains why $\pm 1$ pixel is nowhere near good enough.

---

## 5. Sub-pixel corner refinement

### 5.1 What a pixel is worth, in millimetres

Everything downstream inherits the corner accuracy, so it is worth converting pixels into
the units the clinic cares about before deciding how hard to work here.

A marker of physical side $L$ at depth $Z$ spans

$$
p \;=\; \frac{f_x L}{Z} \text{ pixels}
$$

which is §0.2 applied to two corners at once. Invert it to see how depth is *read*:

$$
Z = \frac{f_x L}{p}
\qquad\Longrightarrow\qquad
\left| \frac{dZ}{dp} \right| = \frac{f_x L}{p^2} = \frac{Z}{p}
\qquad\Longrightarrow\qquad
\boxed{\;\delta Z \;=\; \frac{Z}{p}\,\delta p\;}
$$

Read that as: **the depth error is the corner error scaled by (depth ÷ apparent size).**
It has nothing to do with the camera being good or bad. It is pure geometry — depth is
inferred from how much a known length shrinks, so the smaller the thing you measure, the
harder it is to measure how much it shrank.

Put this build's numbers in. The debug print reports a marker side of about 90 px, and
$L = 5$ cm with $f_x = 887$ gives $Z = 887 \times 0.05 / 90 \approx 0.49$ m — so the
device works at roughly half a metre.

| Measured shape | Span $p$ | $\delta Z$ per pixel of corner error |
|---|---|---|
| one 5 cm marker | 90 px | $0.49/90 = 5.4$ mm |
| the whole 14 cm marker constellation (§7.1) | 250 px | $0.49/250 = 2.0$ mm |

**One pixel of corner error is five millimetres of depth error.** For a device measuring
reaching movements in a rehabilitation game, that is the difference between a usable
signal and noise. Refinement takes the corners from $\pm 1$ px to roughly
$\pm 0.1$–$0.3$ px, which is the difference between $\pm 5$ mm and $\pm 1$ mm — and it
costs one line of configuration.

Keep this table in view: it is quoted again in §7.1 to explain why measuring the whole
device beats measuring one marker, and again at the end of §7.1 where the *measured*
jitter turns out to sit exactly where these numbers predict.

### 5.2 The four options, and the one in use

```python
refine_map = {
    "none":     aruco.CORNER_REFINE_NONE,       # keep §4's integer corners
    "subpix":   aruco.CORNER_REFINE_SUBPIX,     # classic gradient-based corner finder
    "contour":  aruco.CORNER_REFINE_CONTOUR,    # ← settings.json default
    "apriltag": aruco.CORNER_REFINE_APRILTAG,   # AprilTag's own edge refinement
}
```

`contour` is what runs. It is the natural choice for this target because a marker's sides
are long straight high-contrast edges, and the method below exploits exactly that.

### 5.3 Fitting a line to one side — total least squares

For each of the four sides, collect the contour pixels lying along it (§4.4 — around 80–90
of them) and fit a straight line.

**Why not ordinary least squares.** The familiar fit minimises $\sum (y_k - m x_k - c)^2$,
the sum of squared *vertical* offsets. Two things make it wrong here. It blows up for a
near-vertical side, since $m \to \infty$; and it measures error in the wrong direction —
the uncertainty in a thresholded edge pixel is perpendicular to the edge, not vertical.

**The right formulation.** Write the line implicitly as

$$
a x + b y + c = 0, \qquad a^2 + b^2 = 1
$$

The constraint is not cosmetic. With $a^2 + b^2 = 1$, the quantity $|a x_k + b y_k + c|$
*is* the perpendicular distance from the point to the line. So

$$
S(a,b,c) = \sum_{k=1}^{N} (a x_k + b y_k + c)^2
$$

is genuinely the sum of squared perpendicular distances. This is **total least squares**,
and it treats both coordinates symmetrically.

**Step 1 — eliminate $c$.** Differentiate and set to zero:

$$
\frac{\partial S}{\partial c} = 2\sum_k (a x_k + b y_k + c) = 0
\qquad\Longrightarrow\qquad
c = -(a \bar{x} + b \bar{y})
$$

where $\bar{x}, \bar{y}$ are the means. Substituting back, $a\bar x + b \bar y + c = 0$ —
**the best-fit line passes through the centroid of the points**, whatever $a$ and $b$ turn
out to be. That is a result, not an assumption, and it is worth noticing on its own.

**Step 2 — what is left.** Put that $c$ back into $S$ and write
$\tilde{x}_k = x_k - \bar{x}$, $\tilde{y}_k = y_k - \bar{y}$ for the centred points:

$$
S = \sum_k \left( a \tilde{x}_k + b \tilde{y}_k \right)^2
= \begin{bmatrix} a & b \end{bmatrix}
\underbrace{\begin{bmatrix} \sum \tilde{x}_k^2 & \sum \tilde{x}_k \tilde{y}_k \\[2pt] \sum \tilde{x}_k \tilde{y}_k & \sum \tilde{y}_k^2 \end{bmatrix}}_{\textstyle \mathbf{C} \;-\; \text{scatter matrix}}
\begin{bmatrix} a \\ b \end{bmatrix}
\;=\; \mathbf{n}^\top \mathbf{C}\, \mathbf{n}
$$

**Step 3 — minimise.** The problem is now: minimise $\mathbf{n}^\top \mathbf{C} \mathbf{n}$
subject to $\|\mathbf{n}\| = 1$. That quotient is the Rayleigh quotient of the symmetric
matrix $\mathbf{C}$, and its minimum over unit vectors is the **smallest eigenvalue**,
attained at the corresponding eigenvector. So

$$
\mathbf{n} = (a, b) = \text{eigenvector of } \mathbf{C} \text{ with the smallest eigenvalue},
\qquad
c = -(a\bar{x} + b\bar{y})
$$

**Step 4 — read it geometrically.** $\mathbf{C}$ is (up to a factor $N$) the covariance of
the pixel cloud. Its eigenvectors are the cloud's principal axes. For pixels strung along a
straight edge the cloud is a long thin sliver: the **largest** eigenvalue's direction runs
*along* the edge; the **smallest** runs *across* it. And "across the edge" is precisely the
line's normal direction $(a, b)$. The algebra and the picture agree — the fit is finding
the sliver's thin direction.

### 5.4 The corner is where two fitted lines cross

With sides 1 and 2 fitted as $a_1 x + b_1 y + c_1 = 0$ and $a_2 x + b_2 y + c_2 = 0$,
their intersection solves

$$
\begin{bmatrix} a_1 & b_1 \\ a_2 & b_2 \end{bmatrix}
\begin{bmatrix} x \\ y \end{bmatrix}
=
\begin{bmatrix} -c_1 \\ -c_2 \end{bmatrix}
$$

By Cramer's rule, with $D = a_1 b_2 - a_2 b_1$:

$$
x = \frac{b_1 c_2 - b_2 c_1}{D},
\qquad
y = \frac{a_2 c_1 - a_1 c_2}{D}
$$

**The determinant is not just bookkeeping.** Both normals are unit vectors, so

$$
D = a_1 b_2 - a_2 b_1 = \sin \phi
$$

where $\phi$ is the angle between the two sides. A square viewed face-on has
$\phi = 90°$, $D = 1$, and the intersection is beautifully conditioned. Tilt the marker
until it is nearly edge-on and $\phi \to 0$, $D \to 0$, and small errors in either line are
divided by a small number — the corner estimate degrades sharply. This is the concrete
mechanism behind an observation any user of these systems makes eventually: *markers seen
at a grazing angle are unreliable.*

### 5.5 Why fitting beats measuring the corner directly

Two independent reasons, and both are worth stating because they explain why the gain is
as large as it is.

**Averaging.** Each contour pixel's position carries roughly independent error of standard
deviation $\sigma$ (thresholding noise, sensor noise, print edge roughness). Fitting a line
through $N$ of them averages that error down like $\sigma/\sqrt{N}$. With $N \approx 85$
pixels per side, $\sqrt{85} \approx 9$ — about a ninefold improvement, which is exactly the
$\pm 1 \to \pm 0.1$ px quoted above.

**The corner pixel is the worst pixel to trust.** Thresholding rounds sharp convex
corners: the ink density falls off, the local window average shifts, and the outermost
corner pixel is systematically pulled inward. That is a *bias*, not noise, so no amount of
averaging over frames removes it. The line-fitting method never looks at the corner at all
— it measures the two sides, where the edge is clean and long, and extrapolates to their
meeting point. It infers the corner rather than observing it.

That second reason also explains a design choice much later in the pipeline: §7.2 weights
each marker by its projected pixel area, because a marker that is larger in the image has
more contour pixels per side and therefore proportionally more precise corners.

---

## 6. Pose estimation — from corners to a pose

### 6.1 Why four corners — one pixel gives only a ray

Before the solver, the question it answers. §4 and §5 produced pixel coordinates; the goal is
a 3D pose. So why not simply run the projection of §1.1 backwards, one corner at a time?

Because it does not reach a 3D point. This subsection runs the inverse as far as it goes and
shows exactly where it stops — that wall is what the rest of §6 and §7 exist to get around.
Unlike §1, the eight parameters are now known numbers (§2), so every step here is something
you can actually evaluate.

The forward model of §1.1 ran a 3D point through four stages: perspective division, then
$\theta = \arctan r$, then the polynomial warp, then $\mathbf{K}$. Going backwards means
undoing those four in reverse order, and they are not equally cooperative:

| Undoing | How |
|---|---|
| $\mathbf{K}$ | plain algebra — subtract, divide |
| the polynomial | no formula exists; solved numerically |
| $\theta = \arctan r$ | plain algebra — take $\tan$ |
| perspective division | **impossible** — the information is gone |

So four steps of arithmetic get you most of the way back, and then stop short of a 3D point.

**Step 1 — undo $\mathbf{K}$.** $\mathbf{K}$ multiplied by $f$ and added $c$, so its inverse
subtracts $c$ and divides by $f$:

$$
\begin{bmatrix} x_d \\ y_d \\ 1 \end{bmatrix}
=
\underbrace{
\begin{bmatrix}
\dfrac{1}{f_x} & 0 & -\dfrac{c_x}{f_x} \\[6pt]
0 & \dfrac{1}{f_y} & -\dfrac{c_y}{f_y} \\[6pt]
0 & 0 & 1
\end{bmatrix}
}_{\mathbf{K}^{-1}}
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
\qquad\text{i.e.}\qquad
x_d = \frac{u - c_x}{f_x}, \quad y_d = \frac{v - c_y}{f_y}
$$

These are the same $(x_d, y_d)$ as in §1.1 — the *warped* ratios. They are not yet $X/Z$ and
$Y/Z$; the lens is still in the way.

**Step 2 — read off the distorted radius $\theta_d$.** This step looks like it comes from
nowhere, so here is where it comes from. The forward warp scaled *both* coordinates by the
same factor $\theta_d/r$:

$$
x_d = \frac{\theta_d}{r}\,a, \qquad y_d = \frac{\theta_d}{r}\,b, \qquad r = \sqrt{a^2+b^2}
$$

Take the length of that pair and the $r$ cancels against the $r$ hidden in $\sqrt{a^2+b^2}$:

$$
\sqrt{x_d^2 + y_d^2} \;=\; \frac{\theta_d}{r}\sqrt{a^2+b^2} \;=\; \frac{\theta_d}{r}\cdot r
\;=\; \boxed{\theta_d}
$$

That is the whole trick: *the radius of the distorted point is $\theta_d$ itself.* One
`hypot` call recovers the input to the polynomial.

**Step 3 — undo the polynomial, $\theta_d \to \theta$.** Now solve

$$
\theta_d = \theta\left(1 + k_1\theta^2 + k_2\theta^4 + k_3\theta^6 + k_4\theta^8\right)
$$

for $\theta$, with $\theta_d$ known. This is a degree-9 polynomial in $\theta$, and no
rearrangement gives $\theta$ in terms of $\theta_d$ — there is no inverse formula to write
down. OpenCV runs a few Newton iterations per point instead. This is the only inexact step
here; everything before and after it is closed-form.

**Step 4 — undo $\theta = \arctan r$, and rescale.** The forward direction took $\arctan$, so
the reverse takes $\tan$ — that is the whole reason a $\tan$ shows up in a model whose forward
form had an $\arctan$:

$$
r = \tan\theta
$$

With $r$ back in hand, Step 2's relations invert directly:

$$
a = \frac{r}{\theta_d}\,x_d = \frac{\tan\theta}{\theta_d}\,x_d,
\qquad
b = \frac{r}{\theta_d}\,y_d = \frac{\tan\theta}{\theta_d}\,y_d
$$

and $(a, b)$ are the true pinhole ratios $X/Z$ and $Y/Z$. The lens is now fully removed.

**Step 5 — the wall.** Knowing $X/Z$ and $Y/Z$ is not knowing $X$, $Y$, $Z$. What you have is
a *direction*:

$$
\boxed{\;
\begin{bmatrix} X \\ Y \\ Z \end{bmatrix} = \lambda \begin{bmatrix} a \\ b \\ 1 \end{bmatrix},
\qquad \lambda > 0 \text{ unknown}
\;}
$$

The pixel $(u,v)$ tells you the *ray* along which the 3D point must lie — but every point on
that ray produces the identical pixel. The scale $\lambda$ (equivalently, the depth $Z$) was
destroyed by the perspective division in the forward model, and no amount of algebra brings
it back.

**The four steps as one equation.** Steps 1 and 4 are both matrix multiplications, so the
chain collapses to the mirror image of §1.1:

$$
\begin{bmatrix} X \\ Y \\ Z \end{bmatrix}
= \lambda \;
\underbrace{
\begin{bmatrix} \dfrac{\tan\theta}{\theta_d} & 0 & 0 \\[6pt] 0 & \dfrac{\tan\theta}{\theta_d} & 0 \\[6pt] 0 & 0 & 1 \end{bmatrix}
}_{\mathbf{S}^{-1}(\theta) \;-\; \text{undo the warp}}
\underbrace{
\begin{bmatrix}
\dfrac{1}{f_x} & 0 & -\dfrac{c_x}{f_x} \\[6pt]
0 & \dfrac{1}{f_y} & -\dfrac{c_y}{f_y} \\[6pt]
0 & 0 & 1
\end{bmatrix}
}_{\mathbf{K}^{-1}}
\begin{bmatrix} u \\ v \\ 1 \end{bmatrix}
$$

Read it as a summary, not as a recipe. You cannot evaluate it right-to-left in one pass,
because $\mathbf{S}^{-1}$ contains $\theta$ — and $\theta$ is not available until Steps 2 and
3 have already been run on the output of $\mathbf{K}^{-1}$. The matrix form hides the
iteration; the five steps above are what the code actually does.

**Worked numerical example.** Reusing §0.5's camera ($f_x = f_y = 800$, $c_x = 640$,
$c_y = 400$) with this build's real distortion coefficients from `camera_calib.toml`
($k_1 = 0.330$, $k_2 = 0.555$, $k_3 = -1.400$, $k_4 = 1.254$). Take the pixel
$(u, v) = (1240, 400)$ — 600 px right of centre, vertically centred, so near the right edge
of the 1280-wide image.

*Step 1:*

$$
x_d = \frac{1240 - 640}{800} = 0.75, \qquad y_d = \frac{400-400}{800} = 0
$$

*Step 2:* $\theta_d = \sqrt{0.75^2 + 0^2} = 0.75$.

*Step 3:* solve $0.75 = \theta(1 + 0.330\theta^2 + 0.555\theta^4 - 1.400\theta^6 + 1.254\theta^8)$.
Two trial values bracket it:

| $\theta$ | forward polynomial gives $\theta_d$ |
|---|---|
| $0.640$ | $0.7472$ — too small |
| $0.650$ | $0.7625$ — too big |

Newton converges to $\theta = 0.6419$ rad $= 36.78^\circ$. That is the actual angle between
the incoming light ray and the optical axis.

*Step 4:* $r = \tan(0.6419) = 0.7475$, so the rescale factor is
$r/\theta_d = 0.7475/0.75 = 0.9967$, giving

$$
a = 0.9967 \times 0.75 = 0.7475, \qquad b = 0.9967 \times 0 = 0
$$

*Step 5:* the ray is $(X, Y, Z) = \lambda\,(0.7475,\; 0,\; 1)$. At $\lambda = 0.5$ that is the
point $(0.374,\, 0,\, 0.5)$; at $\lambda = 1.0$ it is $(0.7475,\, 0,\, 1.0)$. **Both land on
pixel $(1240, 400)$**, and so does every other point on that line. This is Step 5's wall made
concrete — one pixel, infinitely many 3D points.

*What the distortion model bought:* skipping Steps 2–4 and treating $x_d = 0.75$ as a true
pinhole ratio would put the ray at $\arctan(0.75) = 36.87^\circ$ instead of $36.78^\circ$ — a
lateral error of 2.5 mm at 1 m depth, growing towards the image corners. Small for one ray,
and not small once four of them have to agree on a single pose.

**Where the missing depth comes from.** Nothing above can supply $\lambda$, and that is not a
gap in the algebra — it is the reason this section exists. Depth arrives only with outside
information: **four corners of a marker whose physical size is known** (§6.2, next), or
**many corners of a device whose geometry is known** (§7). Given $n$ such pixels you get $n$
rays and $n$ unknown $\lambda_i$, but the points must *also* sit at known distances from each
other on a rigid body. That constraint is what pins the $\lambda_i$ down, and it is what
turns $n$ rays into one pose.

### 6.2 The PnP problem

§6.1 ended at a wall: a pixel yields a ray, and the depth along it is gone. The way past
the wall was named there — **outside information about how the observed points are
arranged in 3D**. This section spends it.

`cv2.solvePnP(obj_points, img_points, K, np.zeros(5), flags=...)`

**The problem.** Given the 3D positions of the marker's four corners in the *marker's own
frame*,

$$
{}_{\text{mkr}}\mathbf{X}_i = \left\{
\begin{pmatrix} -L/2 \\ L/2 \\ 0 \end{pmatrix},
\begin{pmatrix} L/2 \\ L/2 \\ 0 \end{pmatrix},
\begin{pmatrix} L/2 \\ -L/2 \\ 0 \end{pmatrix},
\begin{pmatrix} -L/2 \\ -L/2 \\ 0 \end{pmatrix} \right\}
$$

with $L = 5$ cm (`board.MARKER_LENGTH`), and the pixels $\mathbf{x}_i = (u_i, v_i)$ where
§5 refined them to, find $\mathbf{R}$ and $\mathbf{t}$ such that

$$
\lambda_i \begin{bmatrix} u_i \\ v_i \\ 1 \end{bmatrix}
= \mathbf{K}\left( \mathbf{R}\, {}_{\text{mkr}}\mathbf{X}_i + \mathbf{t} \right)
\qquad \text{for } i = 1 \ldots 4
$$

for some positive depths $\lambda_i$. This is the **Perspective-$n$-Point** problem, PnP,
with $n = 4$.

**Why it is now solvable — count.** $\mathbf{R}$ carries 3 degrees of freedom and
$\mathbf{t}$ carries 3, so there are **6 unknowns**. Each corner contributes 2 equations
(its $u$ and its $v$; the $\lambda_i$ are eliminated by the same cross-multiplication as
§4.6), so four corners give **8 equations**. Overdetermined by 2.

The surplus is not waste — it is the whole reason the pipeline can check itself. With
exactly 6 equations any pose could be made to fit, and there would be no such thing as a
reprojection error. Two spare equations mean a wrong pose leaves visible residue, and that
residue is what `BOARD_MAX_REPROJ_PX`, the stereo rejection gate, and the calibration
self-checks all read.

(For contrast: three points give 6 equations for 6 unknowns — exactly determined, and
famously it admits up to **four** distinct valid solutions. That is the P3P problem. Four
points is the first count at which the answer is generally unique.)

**Why the marker's own frame.** The object points above are *exact by construction* — they
are the corners of a printed square whose side was measured once. No estimation went into
them. This is the same principle as the calibration chessboard in §2: you supply a known
3D shape, and the unknown is only where it currently sits. And the same warning applies —
if $L$ is wrong, every distance the tracker reports is scaled by the same factor, silently
(§2, "what the verification cannot catch").

### 6.3 Solving the planar case by decomposing a homography

Here is the payoff for §4.6. That section proved that a flat marker's image is governed by

$$
\mathbf{H} = \mathbf{K}\,[\,\mathbf{r}_1 \mid \mathbf{r}_2 \mid \mathbf{t}\,]
\qquad \text{(up to scale)}
$$

The detector computed $\mathbf{H}$ to read the bits. Now read it for what it contains:
two columns of a rotation matrix and a translation vector — the pose itself, sitting in
plain sight. Extracting it takes four steps.

**Step 1 — strip the camera off.** $\mathbf{K}$ is known from §2, so multiply it out:

$$
\mathbf{M} \;=\; \mathbf{K}^{-1}\mathbf{H}
\;=\; s\,[\,\mathbf{r}_1 \mid \mathbf{r}_2 \mid \mathbf{t}\,]
$$

The unknown scalar $s$ survives because $\mathbf{H}$ was only ever defined up to scale
(§4.6). Write $\mathbf{M}$'s columns as $\mathbf{m}_1, \mathbf{m}_2, \mathbf{m}_3$.

**Step 2 — recover the scale from the fact that $\mathbf{R}$ is a rotation.** The columns
of a rotation matrix are unit vectors. So $\|\mathbf{m}_1\| = s\|\mathbf{r}_1\| = s$, and
likewise for $\mathbf{m}_2$. Two independent readings of the same number, so average them:

$$
s = \frac{\|\mathbf{m}_1\| + \|\mathbf{m}_2\|}{2}
$$

This is the step where **absolute scale enters the pipeline**. Note what supplied it: the
knowledge that $\mathbf{r}_1$ and $\mathbf{r}_2$ have length one — which is true only
because the object points were given in metres with the correct $L$. Nothing in the image
knows how big anything is.

**Step 3 — read off the pose.**

$$
\mathbf{r}_1 = \frac{\mathbf{m}_1}{s}, \qquad
\mathbf{r}_2 = \frac{\mathbf{m}_2}{s}, \qquad
\mathbf{t} = \frac{\mathbf{m}_3}{s}, \qquad
\mathbf{r}_3 = \mathbf{r}_1 \times \mathbf{r}_2
$$

The third column is *recovered*, not measured — it was annihilated back in §4.6 when
$Z = 0$ killed it, and the cross product puts it back using the fact that a rotation
matrix's columns are mutually perpendicular and right-handed. The sign of $s$ is chosen so
that $t_z > 0$: the marker must be in front of the camera, not behind it.

**Step 4 — repair the rotation.** With noisy corners, $[\,\mathbf{r}_1 \mid \mathbf{r}_2 \mid \mathbf{r}_3\,]$
comes out *nearly* orthonormal but not exactly. The standard repair is to take its SVD,
$\mathbf{U}\boldsymbol{\Sigma}\mathbf{V}^\top$, and set

$$
\mathbf{R} = \mathbf{U}\mathbf{V}^\top
$$

which is the closest true rotation in the least-squares sense (the orthogonal Procrustes
solution). Intuitively: the SVD writes the matrix as *rotate, stretch by
$\boldsymbol{\Sigma}$, rotate*; discarding the stretch leaves the rotation.

> **Level of rigour.** The four steps above are the classical homography decomposition,
> and they genuinely produce a pose from a planar target. `SOLVEPNP_IPPE_SQUARE`
> implements a different route to the same answer — Collins & Bartoli's IPPE (2014) works
> from the first-order behaviour of $\mathbf{H}$ at the marker's centre and obtains its
> solutions in closed form, which is numerically better behaved. The structure of the
> result is the same in both, and the structure is what §6.4 is about.

### 6.4 The two-solution ambiguity — and why it is the pipeline's worst failure mode

A planar PnP problem has, in general, **two** solutions, and the solver returns both.

**Why two.** At typical working distance, a 5 cm marker occupies a small angular slice of
the field of view, so the perspective across the marker itself is weak — the projection
over that small patch is nearly *affine* (parallel lines stay parallel). Now: an affine
projection of a tilted square cannot tell a tilt from its mirror image. Tilt the top edge
away from the camera by 30°, or tilt it *toward* the camera by 30°, and to first order the
square projects to the *same* trapezoid. The information that separates them is the tiny
second-order difference — the near edge being genuinely closer and therefore very slightly
larger — and that difference can be a fraction of a pixel.

**Why it hurts so much.** The two poses can differ by tens of degrees in tilt while their
reprojection errors differ by less than the corner noise. So the solver's choice between
them is made by noise. Frame to frame it flips, the marker's estimated orientation snaps
back and forth, and — because §7.2 propagates orientation through a 12 cm lever arm to
reach the grip point — the reported position jumps by millimetres. This is the single
largest source of jitter in the superseded per-marker method.

**Three things kill it**, and the pipeline uses all three:

| Defence | Where | Why it works |
|---|---|---|
| use a previous-frame guess | §6.5, `SOLVEPNP_ITERATIVE` | the iterative solver descends to the *nearest* minimum, and the true pose is the one near where the device was a hundredth of a second ago |
| make the point set non-coplanar | §7.1 | the ambiguity is a theorem about *planar* targets; two markers on angled faces are not coplanar and the mirrored solution reprojects visibly wrongly |
| add a second camera | §7.4 | the mirrored pose is mirrored about *that camera's* line of sight, so a camera elsewhere disagrees loudly |

### 6.5 Which solver actually runs

> **This corrects the earlier version of this document,** which described `IPPE_SQUARE` as
> the solver. That is the default of `settings.json`'s `pnp_method`, but that setting is
> only consulted by `MainClass.estimate_pose` — the **superseded** per-marker path of
> §7.2. The deployed rigid-body path routes through `board.estimate_board_pose`, which
> chooses its own solver per frame.

```python
if guess is not None:                 # → SOLVEPNP_ITERATIVE, useExtrinsicGuess=True
elif len(used_ids) >= 2:              # → SOLVEPNP_SQPNP
else:                                 # → SOLVEPNP_IPPE_SQUARE on the lone marker
```

**`SOLVEPNP_ITERATIVE` — the steady-state case.** This is Levenberg–Marquardt applied
directly to the thing you actually care about:

$$
\min_{\mathbf{R},\mathbf{t}} \; \sum_i \left\| \operatorname{project}(\mathbf{K}, \mathbf{R}\mathbf{X}_i + \mathbf{t}) - \mathbf{u}_i \right\|^2
$$

Stack the residuals into $\mathbf{r}$ and let $\mathbf{J}$ be their Jacobian with respect
to the 6 pose parameters. Each step solves

$$
\left( \mathbf{J}^\top\mathbf{J} + \mu \mathbf{I} \right) \boldsymbol{\delta} = -\,\mathbf{J}^\top \mathbf{r}
$$

and updates the pose by $\boldsymbol{\delta}$. The damping $\mu$ interpolates between two
classical methods: at $\mu \to 0$ this is Gauss–Newton, which converges fast when close;
at large $\mu$ it becomes a small step along $-\mathbf{J}^\top\mathbf{r}$, i.e. gradient
descent, which is safe when far away. LM raises $\mu$ when a step makes things worse and
lowers it when a step helps.

The consequence that matters operationally: **it finds a local minimum near where it
started.** Fed the previous frame's pose, that is a feature — it lands on the true pose
rather than the mirrored one, resolving §6.4's ambiguity for free.

But it also means a *stale* guess is dangerous. After fast motion or re-entry from an
occlusion, the previous pose may be nearer the wrong minimum, and LM will converge
confidently into it. `main.py` guards this by checking the answer rather than trusting it:

```python
if guess is not None and reproj > Config.BOARD_MAX_REPROJ_PX:   # 3.0 px
    fresh = estimate_board_pose(..., guess=None)                # re-solve from scratch
    if fresh is not None and fresh[2] < reproj:
        rvec, tvec, reproj = fresh
```

This is §6.2's spare-equations point paying off: without the surplus constraints there
would be no reprojection error to test, and the bad pose would pass silently.

**`SOLVEPNP_SQPNP` — cold start with two or more markers.** No initial guess is available
(first frame, or just after a re-lock), and the corners come from several markers on
angled faces, so the point set is genuinely three-dimensional. SQPnP (Terzakis & Lourakis,
2020) treats PnP as a constrained optimisation over the 9 entries of $\mathbf{R}$ subject
to the orthonormality constraints, and solves it by sequential quadratic programming from
several starting points — so it finds the **global** optimum without being told where to
look. Non-coplanar points, global solver, no ambiguity.

**`SOLVEPNP_IPPE_SQUARE` — cold start with a single marker.** Only one marker visible and
no guess: the point set is unavoidably planar, so §6.3's method is exactly right and
§6.4's ambiguity is unavoidable. This is the degenerate case, and the code is honest about
it — the pose is solved for the marker, then *composed* with the marker's known place on
the device.

**That composition, derived.** `solvePnP` returns the marker's pose in the camera frame:

$$
{}_{\text{cam}}\mathbf{p} = \mathbf{R}_{cm}\,{}_{\text{mkr}}\mathbf{p} + \mathbf{t}_{cm}
$$

and `board_geometry.json` stores the marker's fixed pose on the device:

$$
{}_{\text{board}}\mathbf{p} = \mathbf{R}_{bm}\,{}_{\text{mkr}}\mathbf{p} + \mathbf{t}_{bm}
$$

We want the *board's* pose in the camera frame. Invert the second relation — legitimate
because $\mathbf{R}_{bm}^{-1} = \mathbf{R}_{bm}^\top$ for a rotation:

$$
{}_{\text{mkr}}\mathbf{p} = \mathbf{R}_{bm}^\top\left( {}_{\text{board}}\mathbf{p} - \mathbf{t}_{bm} \right)
$$

and substitute into the first:

$$
{}_{\text{cam}}\mathbf{p}
= \mathbf{R}_{cm}\mathbf{R}_{bm}^\top\, {}_{\text{board}}\mathbf{p}
\;+\; \underbrace{\mathbf{t}_{cm} - \mathbf{R}_{cm}\mathbf{R}_{bm}^\top\,\mathbf{t}_{bm}}_{\text{constant}}
$$

Matching this against ${}_{\text{cam}}\mathbf{p} = \mathbf{R}_{cb}\,{}_{\text{board}}\mathbf{p} + \mathbf{t}_{cb}$
gives

$$
\boxed{\;\mathbf{R}_{cb} = \mathbf{R}_{cm}\mathbf{R}_{bm}^\top,
\qquad
\mathbf{t}_{cb} = \mathbf{t}_{cm} - \mathbf{R}_{cb}\,\mathbf{t}_{bm}\;}
$$

which is line for line what `board.py` computes:

```python
R_cb = R_pnp @ R_bm.T
t_cb = t_m.flatten() - R_cb @ t_bm
```

The single-marker case therefore still reports a *board* pose, so §8 downstream never
needs to know how many markers were visible.

**Why `np.zeros(5)` for distortion, everywhere.** The frame was undistorted in §3, so by
the time any solver sees it, it genuinely is a pinhole image with intrinsics $\mathbf{K}$.
Passing real distortion coefficients here would apply the lens warp a second time.

### 6.6 Rodrigues vectors — why poses travel as three numbers

Every function above passes rotations as `rvec`, a 3-vector, and `cv2.Rodrigues` converts
between that and a $3 \times 3$ matrix. The reason is a counting argument.

A rotation has **3** degrees of freedom: pick an axis (2 numbers, a direction on the
sphere) and an angle about it (1 number). A $3 \times 3$ matrix has 9 entries, so the
orthonormality conditions $\mathbf{R}^\top\mathbf{R} = \mathbf{I}$ must be imposing 6
constraints — and they do: three columns of unit length, three pairwise perpendicularity
conditions. Storing 9 numbers to carry 3 is fine for computation and bad for optimisation,
because LM in §6.5 would have to keep 6 constraints satisfied while stepping.

The **Rodrigues vector** stores the 3 directly:

$$
\mathbf{r} = \theta\,\hat{\mathbf{n}},
\qquad \theta = \|\mathbf{r}\| = \text{angle},
\qquad \hat{\mathbf{n}} = \mathbf{r}/\|\mathbf{r}\| = \text{axis}
$$

and the matrix is recovered by Rodrigues' rotation formula,

$$
\mathbf{R} = \mathbf{I} + \sin\theta\,[\hat{\mathbf{n}}]_\times + (1 - \cos\theta)\,[\hat{\mathbf{n}}]_\times^2,
\qquad
[\hat{\mathbf{n}}]_\times = \begin{bmatrix} 0 & -n_z & n_y \\ n_z & 0 & -n_x \\ -n_y & n_x & 0 \end{bmatrix}
$$

often written $\mathbf{R} = \exp([\mathbf{r}]_\times)$.

**Reading the angle back out.** This appears in the stereo disagreement gate and in
`pose_averaging.py`, so it is worth deriving rather than quoting. Take the trace of
Rodrigues' formula. The cross-product matrix has $\operatorname{tr}[\hat{\mathbf{n}}]_\times = 0$
(its diagonal is zeros), and a short computation gives
$\operatorname{tr}[\hat{\mathbf{n}}]_\times^2 = -2$ for a unit axis. So

$$
\operatorname{tr}\mathbf{R} = 3 + \sin\theta \cdot 0 + (1-\cos\theta)(-2) = 1 + 2\cos\theta
$$

$$
\Longrightarrow\qquad
\boxed{\;\theta = \arccos\!\left( \frac{\operatorname{tr}\mathbf{R} - 1}{2} \right)}
$$

which is exactly `pose_averaging.rotation_angle`:

```python
def rotation_angle(R):
    return float(np.arccos(np.clip((np.trace(R) - 1) / 2, -1.0, 1.0)))
```

Applied to $\mathbf{R}_A \mathbf{R}_B^\top$ it gives the angle *between* two orientations,
which is how §7.4 decides whether two cameras agree.

---

## 7. Combining markers into one device pose

§6 solves for the pose of *a marker*. The game needs the position of *the grip point* —
the spot on the handle the patient's hand holds. Those are different things, and this
section closes the gap.

The device carries markers on several faces (IDs 12 front, 14 front-top, 20/24 back sides,
plus 4, 8, 28, 32 on the reprint); typically 1–3 are visible in any frame, and *which* ones
changes constantly as the hand rotates. So the section has to answer two questions at once:
how to get from a marker to the grip, and how to combine several markers that each have
their own opinion about where it is.

**The joint rigid-body solve (§7.1) is what runs today.** The per-marker average (§7.2) is
the superseded method, kept here because it is still the fallback when board geometry is
missing, and because it is the baseline that [rigid_body_math.md](rigid_body_math.md)
measures against.

### 7.1 Joint rigid-body solve — deployed

**The idea in one sentence:** the markers are glued to one rigid object, so they do not
have separate poses — they have one pose, and every visible corner is evidence about it.

`calibrate_board.py` measures the constellation once (§7.3) and stores, for each marker
$i$, its fixed pose in the **board frame**:

$$
{}_{\text{board}}\mathbf{X} = \mathbf{R}^{b}_{i}\, {}_{\text{mkr}_i}\mathbf{X} + \mathbf{t}^{b}_{i}
$$

Applying that to the four known corner coordinates $\mathbf{X}_k$ of each marker gives
every corner's fixed position on the device:

$$
{}_{\text{board}}\mathbf{X}_{i,k} = \mathbf{R}^{b}_{i} \mathbf{X}_k + \mathbf{t}^{b}_{i}
$$

These constants live in `board_geometry.json`, together with one consensus grip point
${}_{\text{board}}\mathbf{g}$.

At runtime, whatever subset $V$ of markers happens to be visible, **all** their corners go
into a **single** PnP problem with **one** unknown pose:

$$
\min_{\mathbf{R},\, \mathbf{t}} \; \sum_{i \in V} \sum_{k=1}^{4}
\left\| \operatorname{project}\!\left(\mathbf{K},\; \mathbf{R}\, {}_{\text{board}}\mathbf{X}_{i,k} + \mathbf{t}\right) - \mathbf{u}_{i,k} \right\|^2
$$

and the grip point follows directly — no voting, no averaging, no weights:

$$
{}_{\text{cam}}\mathbf{g} = \mathbf{R}\, {}_{\text{board}}\mathbf{g} + \mathbf{t}
$$

**Why this is better — the counting.** With three markers visible, the old way solved
3 separate 6-unknown problems from 8 measurements each: a constraint ratio of
$8/6 \approx 1.3$, with each point set coplanar. The joint solve has 24 measurements
against 6 unknowns — ratio 4 — over a point set that is genuinely three-dimensional.

**Why this is better — the depth argument, quantified.** §5.1 derived

$$
\delta Z = \frac{Z}{p}\,\delta p
$$

where $p$ is the pixel span of whatever shape is being measured. That formula is the
entire argument, because it says depth precision is set by the *span of the measured
shape*, not by the number of markers or the quality of the solver:

| Measured shape | Span $p$ at $Z \approx 0.5$ m | $\delta Z$ per pixel |
|---|---|---|
| one 5 cm marker | ~90 px | 5.4 mm |
| the whole constellation | ~250 px | 2.0 mm |

A factor of 2.7 improvement in depth precision, from measuring a bigger thing. On top of
that, pooling 24 corners instead of 8 averages the corner noise down by a further
$\sqrt{24/8} = \sqrt{3} \approx 1.7$.

**Why this is better — the ambiguity dies.** §6.4's two-solution problem is a theorem
about *coplanar* point sets. The device's faces are angled relative to each other, so once
two non-parallel markers are visible the point set is not planar, the mirrored pose
reprojects visibly wrongly, and the second minimum simply does not exist.

**The measured result.** Across 43 workspace positions, median device wobble at rest fell
from **3.27 mm to 0.78 mm** — a 5.2× reduction (`tools/analyze_jitter.py`).

It is worth checking that against the table above rather than just accepting it. The old
method's 3.27 mm corresponds to $3.27/5.4 \approx 0.6$ px of effective corner error; the
new method's 0.78 mm corresponds to $0.78/2.0 \approx 0.4$ px. Both sit right in the
$\pm 0.1$–$0.3$ px range §5 promised, once you account for orientation error reaching the
grip through the lever arm. The derivation and the measurement agree — which is the
strongest evidence available that the model of the pipeline in this document is the right
one.

**Degradation.** With only one marker visible the problem necessarily reduces to
single-marker quality: 8 measurements, coplanar, ambiguity live. Board geometry cannot
supply constraints the image does not contain. What it *does* still supply is the
composition of §6.5 — the answer is reported in the board frame either way, so nothing
downstream changes.

### 7.2 Per-marker average — superseded

For each visible marker $i$, `solvePnP` gives $\mathbf{R}_i, \mathbf{t}_i$, and a
hand-measured offset ${}_{\text{mkr}_i}\mathbf{o}_i$ (from `board.MARKER_OFFSETS`) points
from that marker's centre to the grip. Each marker independently predicts the grip:

$$
{}_{\text{cam}}\mathbf{g}_i = \mathbf{R}_i \cdot {}_{\text{mkr}_i}\mathbf{o}_i + \mathbf{t}_i
$$

and the predictions are combined by a weighted mean:

$$
{}_{\text{cam}}\mathbf{g} = \frac{\sum_{i \in V} w_i\, {}_{\text{cam}}\mathbf{g}_i}{\sum_{i \in V} w_i}
\qquad w_i = \text{projected pixel area of marker } i
$$

**The weight, derived.** The code computes the area from the quadrilateral's *diagonals*:

```python
d1 = c[2] - c[0]   # top-left  → bottom-right
d2 = c[3] - c[1]   # top-right → bottom-left
weights[index] = 0.5 * abs(d1[0]*d2[1] - d1[1]*d2[0])
```

This is the shoelace formula in disguise. For a quadrilateral with vertices
$\mathbf{c}_1 \ldots \mathbf{c}_4$ in order, the shoelace sum
$\tfrac12\left|\sum_k (x_k y_{k+1} - x_{k+1} y_k)\right|$ regroups exactly into

$$
A = \tfrac{1}{2}\left| (\mathbf{c}_3 - \mathbf{c}_1) \times (\mathbf{c}_4 - \mathbf{c}_2) \right|
= \tfrac{1}{2}\left| \mathbf{d}_1 \times \mathbf{d}_2 \right|
$$

i.e. half the magnitude of the cross product of the two diagonals — the same identity that
gives a rhombus's area as half the product of its diagonals, generalised. Two subtractions
and one cross product instead of four terms.

The reasoning behind using area as the weight is §5.5's: a marker that is larger in the
image has more contour pixels along each side, hence more precise corners, hence a more
trustworthy pose. (The original code used equal weights $w_i = 1$; the
`SETUP:...,equal` command restores that, which is how the old setup is reconstructed for
side-by-side demos.)

**Three structural weaknesses, all removed by §7.1:**

1. **Each solve is weakly constrained.** 8 measurements, 6 unknowns, coplanar points — so
   depth rests entirely on sub-pixel size changes of one small square, at 5.4 mm per pixel
   (§5.1).
2. **The lever arm amplifies rotation error.** Each $\mathbf{R}_i$ is uncertain, and that
   uncertainty is multiplied by the offset length before it reaches the grip. Concretely:
   marker 20 sits $\|\mathbf{o}\| \approx 0.136$ m from the grip, and a rotation error
   $\delta\theta$ displaces the predicted grip by $\|\mathbf{o}\|\,\delta\theta$. At
   $\delta\theta = 1° = 0.0175$ rad that is **2.4 mm** — from one degree. And §6.4's
   ambiguity flips produce errors far larger than one degree.
3. **Disagreement is averaged, not resolved.** The markers are rigidly joined, so they
   *cannot* truly disagree; any disagreement is measurement error, and it is evidence about
   which measurements to distrust. Averaging discards that evidence after the fact instead
   of using it during the solve.

### 7.3 Where the board geometry comes from

`calibrate_board.py` deliberately never uses `MARKER_OFFSETS` — it measures the layout
directly from images, so the result stays valid even when a hand-measured offset is wrong.

**Cancelling the camera out.** In every frame where markers $i$ and $j$ are both visible,
each is solved independently against the camera, giving
$(\mathbf{R}_i, \mathbf{t}_i)$ and $(\mathbf{R}_j, \mathbf{t}_j)$. Both describe
marker → camera:

$$
{}_{\text{cam}}\mathbf{p} = \mathbf{R}_i\,{}_{i}\mathbf{p} + \mathbf{t}_i
= \mathbf{R}_j\,{}_{j}\mathbf{p} + \mathbf{t}_j
$$

Solve the left equality for ${}_{i}\mathbf{p}$ and substitute the right-hand expression for
${}_{\text{cam}}\mathbf{p}$:

$$
{}_{i}\mathbf{p} = \mathbf{R}_i^\top\left( {}_{\text{cam}}\mathbf{p} - \mathbf{t}_i \right)
= \mathbf{R}_i^\top\left( \mathbf{R}_j\,{}_{j}\mathbf{p} + \mathbf{t}_j - \mathbf{t}_i \right)
= \underbrace{\mathbf{R}_i^\top \mathbf{R}_j}_{\mathbf{R}_{ij}}\, {}_{j}\mathbf{p}
+ \underbrace{\mathbf{R}_i^\top\left( \mathbf{t}_j - \mathbf{t}_i \right)}_{\mathbf{t}_{ij}}
$$

$$
\boxed{\;\mathbf{R}_{ij} = \mathbf{R}_i^\top \mathbf{R}_j,
\qquad
\mathbf{t}_{ij} = \mathbf{R}_i^\top (\mathbf{t}_j - \mathbf{t}_i)\;}
$$

Notice what happened: the camera pose appears in both $\mathbf{R}_i$ and $\mathbf{R}_j$ and
**cancels**. $(\mathbf{R}_{ij}, \mathbf{t}_{ij})$ is a fact about the device alone — the
same numbers whatever the camera was doing when the frame was taken. That is why it can be
averaged over hundreds of frames taken at wildly different poses.

Samples are rejected if the fit is poor or if the mirrored tilt of §6.4 fits nearly as
well; then $\ge 30$ surviving samples per pair are averaged with outlier trimming
(`pose_averaging.robust_average_transform`).

**Linking markers that never meet.** The front and back markers cannot face one camera at
the same time, so no frame ever gives $(\mathbf{R}_{ik}, \mathbf{t}_{ik})$ directly. They
are linked by **composing** through a shared neighbour $j$ that has been seen with both.
Substituting ${}_{j}\mathbf{p} = \mathbf{R}_{jk}\,{}_{k}\mathbf{p} + \mathbf{t}_{jk}$ into
${}_{i}\mathbf{p} = \mathbf{R}_{ij}\,{}_{j}\mathbf{p} + \mathbf{t}_{ij}$:

$$
{}_{i}\mathbf{p} = \mathbf{R}_{ij}\left( \mathbf{R}_{jk}\,{}_{k}\mathbf{p} + \mathbf{t}_{jk} \right) + \mathbf{t}_{ij}
$$

$$
\boxed{\;\mathbf{R}_{ik} = \mathbf{R}_{ij}\mathbf{R}_{jk},
\qquad
\mathbf{t}_{ik} = \mathbf{R}_{ij}\mathbf{t}_{jk} + \mathbf{t}_{ij}\;}
$$

Walking outward from the reference marker this way puts every marker into one common
frame. The cost of composing is that errors compose too — a marker two hops from the
reference carries both hops' error — which is why the calibration procedure tries to get
every marker seen alongside the reference where physically possible.

**Self-check before saving.** Each marker independently predicts the grip point via its own
hand-measured offset,

$$
{}_{\text{board}}\mathbf{g}_i = \mathbf{R}^{b}_i \mathbf{o}_i + \mathbf{t}^{b}_i
$$

All of these should land on the same physical spot, since there is only one grip. The
script prints each prediction's distance from their mean and flags any beyond 5 mm. A flag
means either the solved geometry or that particular hand-measured offset is wrong — and
because the two error sources are independent, the pattern of which markers disagree
usually tells you which.

### 7.4 Two cameras — fusing independent solves

Enabled when `camera_backend == "rcam_dual"`. Each camera captures on its own thread,
undistorts with its **own** intrinsics (each OV9281 needs its own `camera_calib_1.toml`),
detects, and solves its own board pose. Two independent estimates of the same physical
pose then have to become one.

**Step 1 — put both in the same frame.** `calibrate_stereo.py` measures the fixed rigid
transform between the cameras: for any point,

$$
{}_{\text{cam}0}\mathbf{p} = \mathbf{R}_x\, {}_{\text{cam}1}\mathbf{p} + \mathbf{t}_x
$$

Cam1 reports the board pose as
${}_{\text{cam}1}\mathbf{p} = \mathbf{R}_1\,{}_{\text{board}}\mathbf{p} + \mathbf{t}_1$.
Substitute:

$$
{}_{\text{cam}0}\mathbf{p}
= \mathbf{R}_x\left( \mathbf{R}_1\,{}_{\text{board}}\mathbf{p} + \mathbf{t}_1 \right) + \mathbf{t}_x
= \underbrace{\mathbf{R}_x\mathbf{R}_1}_{\mathbf{R}_1'}\,{}_{\text{board}}\mathbf{p}
+ \underbrace{\mathbf{R}_x\mathbf{t}_1 + \mathbf{t}_x}_{\mathbf{t}_1'}
$$

matching `_transform_pose_to_cam0` exactly. Same composition rule as §7.3 — the pipeline
uses it three times now, so it is worth recognising rather than re-deriving.

**Step 2 — do they agree?** Compare the two poses before combining them:

$$
\Delta\theta = \arccos\!\left( \frac{\operatorname{tr}\!\left(\mathbf{R}_0 \mathbf{R}_1'^{\top}\right) - 1}{2} \right),
\qquad
\Delta d = \left\| \mathbf{t}_0 - \mathbf{t}_1' \right\|
$$

The first is §6.6's angle formula applied to the relative rotation — if the two agreed
perfectly, $\mathbf{R}_0\mathbf{R}_1'^\top$ would be the identity and $\Delta\theta$ zero.
Beyond `stereo_disagree_rot_deg` (6°) or `stereo_disagree_trans_mm` (20 mm), the pipeline
**does not fuse**: it takes whichever camera has the lower reprojection error and warns
after the disagreement persists 30 frames. The usual cause is a stale stereo calibration —
a bumped camera mount — and the warning names that.

This ordering is deliberate and the code comments say why: weighting can only
*down*-weight a bad estimate, never reject one. A camera that is 5 cm wrong still drags
the fused answer several centimetres off. So rejection has to happen first, as a hard gate,
before any averaging.

**Step 3 — weight by inverse variance.** For translation:

$$
w_0 = \frac{1}{e_0^2}, \qquad w_1 = \frac{1}{e_1^2},
\qquad
\mathbf{t}_{\text{fused}} = \frac{w_0 \mathbf{t}_0 + w_1 \mathbf{t}_1'}{w_0 + w_1}
$$

**Why $1/e^2$ and not, say, $1/e$.** Take two unbiased independent estimates with variances
$\sigma_0^2, \sigma_1^2$ and combine them as $w_0 x_0 + w_1 x_1$ with $w_0 + w_1 = 1$. The
combination's variance is $w_0^2\sigma_0^2 + w_1^2\sigma_1^2$. Substitute $w_1 = 1 - w_0$,
differentiate, set to zero:

$$
2w_0\sigma_0^2 - 2(1-w_0)\sigma_1^2 = 0
\qquad\Longrightarrow\qquad
w_0 = \frac{\sigma_1^2}{\sigma_0^2 + \sigma_1^2}
\qquad\Longrightarrow\qquad
w_i \;\propto\; \frac{1}{\sigma_i^2}
$$

Inverse-variance weighting is the minimum-variance choice, not a heuristic. The
*heuristic* part is the substitution $\sigma_i \to e_i$: reprojection error is used as a
stand-in for the pose's standard deviation. That is plausible — a pose that explains its
corners badly is probably a worse pose — but it is not a derived relationship, and it is
the assumption to revisit if fusion ever behaves oddly.

**Step 4 — averaging the rotations.** Rotation matrices cannot be averaged entrywise: the
mean of two rotation matrices is generally not a rotation (its columns are neither unit
length nor perpendicular). The code converts to quaternions instead:

```python
qa, qb = R_to_quat(Ra), R_to_quat(Rb)
if np.dot(qa, qb) < 0:
    qb = -qb                       # same rotation, opposite hemisphere
q = wa*qa + wb*qb
q /= np.linalg.norm(q)
```

The sign flip is essential and easy to miss. A quaternion $\mathbf{q}$ and its negation
$-\mathbf{q}$ describe the **identical** rotation — the double cover of the rotation group
— so two solvers can return numerically opposite quaternions for poses that are physically
almost the same. Adding them without the flip would give something near zero, and
normalising *that* produces nonsense. Testing $\mathbf{q}_a \cdot \mathbf{q}_b < 0$ and
negating puts both on the same hemisphere first.

The weighted sum followed by renormalisation is an approximation to the true (Markley)
rotation average, and the code says so. It is a good approximation precisely when the two
rotations are close — which Step 2's 6° gate has already guaranteed.

**Step 5 — timing.** Two free-running cameras are not synchronised. `_capture_dual_frames`
compares the frames' capture timestamps and, if they differ by more than
`stereo_max_frame_skew_ms` (20 ms), treats cam1's frame as "not ready" rather than fusing
a mismatched pair. During fast reaching motion 20 ms of skew is real millimetres of
genuine movement, and fusing across it would manufacture an error that neither camera made.

**Graceful degradation.** If one camera's thread dies or its view is blocked,
`_fuse_board_poses` receives `None` for that pose and returns the survivor's — transformed
into cam0's frame first if the survivor is cam1. There is no separate "fall back to single
camera" code path because none is needed; the fusion function's own structure is the
fallback.

---

## 8. World frame — making the numbers mean something

The grip point from §7 is expressed in the **camera frame**: metres right, down, and
forward of a point inside the lens. That is useless to a therapist and useless to the game.
Two things are wrong with it — the origin is arbitrary (inside a lens), and the axes are
arbitrary (whichever way the camera happens to be aimed). Reposition the camera by a
centimetre and every recorded number changes, though the patient moved identically.

So the tracker **locks a world origin**: it picks one moment, records the device's pose
then, and reports everything afterwards relative to that.

**At lock time**, two quantities are saved, both in the camera frame:

$$
\mathbf{R}_{\text{lock}} = \text{the device's orientation at lock},
\qquad
{}_{\text{cam}}\mathbf{g}_{\text{lock}} = \text{the grip point at lock}
$$

In rigid-body mode both come straight from the board pose:
$\mathbf{R}_{\text{lock}} = \mathbf{R}$ and
${}_{\text{cam}}\mathbf{g}_{\text{lock}} = \mathbf{R}\,{}_{\text{board}}\mathbf{g} + \mathbf{t}$.
The axes therefore belong to **the device as a whole**, which was not true of the
per-marker version — there the frame was inherited from whichever marker happened to be
listed first in that frame's detection, so two sessions could lock to different markers and
produce coordinate systems rotated relative to each other.

**Every subsequent frame:**

$$
{}_{\text{world}}\mathbf{p} = \mathbf{R}_{\text{lock}}^\top \left( {}_{\text{cam}}\mathbf{g}_{\text{lock}} - {}_{\text{cam}}\mathbf{g} \right)
$$

**Read it in two pieces.** The bracket is a difference of two points in the camera frame,
which is a *displacement* — and a displacement is already free of the origin problem,
because subtracting two positions cancels whatever the origin was. Left-multiplying by
$\mathbf{R}_{\text{lock}}^\top$ then fixes the axis problem: since
$\mathbf{R}_{\text{lock}}$ takes device-frame vectors into camera-frame vectors, its
transpose (= its inverse, for a rotation) takes camera-frame vectors back into
device-at-lock axes. The result is: **how far the grip has moved since lock, expressed
along the device's own axes at lock time.**

**A sign note.** The bracket is $\mathbf{g}_{\text{lock}} - \mathbf{g}$, not
$\mathbf{g} - \mathbf{g}_{\text{lock}}$, so the reported vector points from the current
grip *back to* the lock point — the negative of the displacement as normally defined. It is
a consistent convention rather than an error, and §11's affine fit absorbs any consistent
sign or scale, since that fit is made from samples produced by this same expression. Worth
knowing before you interpret a raw CSV column by hand.

**Locking is validated, not taken from one frame.** Anchoring an entire session to a single
noisy detection would put a systematic offset into every number that follows. So the lock
commits only after `ORIGIN_LOCK_FRAMES = 10` consecutive frames pass a stability test:

| Mode | Test | Threshold |
|---|---|---|
| single camera | same marker IDs detected, and mean corner motion below | `ORIGIN_STABLE_PX` = 2.0 px |
| dual camera | translation and rotation change of the *fused pose* below | `origin_stable_m` = 2 mm, `origin_stable_rad` ≈ 1° |

The dual-camera case needs a different test for a reason worth stating: two cameras' pixel
spaces are not comparable, so "the corners barely moved" is not a question you can ask
across both. The gate moves into pose space instead, where the two are directly
comparable.

**The lock persists across restarts.** $(\mathbf{R}_{\text{lock}}, {}_{\text{cam}}\mathbf{g}_{\text{lock}})$
are written to `origin_lock.json` and reloaded at startup. Because they are stored **in the
camera frame**, they remain valid exactly as long as the camera does not move — which is
what makes sessions, and patients on an identically-mounted rig, comparable to each other.
Two consequences:

- Moving the camera **silently** invalidates the file. It still loads, it still produces
  plausible numbers, and they no longer describe reality. Delete it and re-lock — the
  installer's origin ritual sends `RELOCK`, which clears memory and file and waits for the
  next stable detection.
- Because the lock lives in the camera frame, data recorded under *different* locks can
  still be reconciled afterwards. Invert the transform:

$$
{}_{\text{cam}}\mathbf{g} = {}_{\text{cam}}\mathbf{g}_{\text{lock}} - \mathbf{R}_{\text{lock}}\, {}_{\text{world}}\mathbf{p}
$$

  (Left-multiply the forward equation by $\mathbf{R}_{\text{lock}}$, use
  $\mathbf{R}\mathbf{R}^\top = \mathbf{I}$, rearrange.) Recover camera-frame coordinates
  from both sessions and they are directly comparable again. This is why every logged data
  file stamps the contents of `origin_lock.json` in its header (see
  [v1_plan.md §6](v1_plan.md)) — the stamp is the undo key, and without it the recording is
  not recoverable.

---

## 9. Smoothing — four filters and one gate

${}_{\text{world}}\mathbf{p}$ is correct on average but noisy frame to frame, and a
visibly trembling cursor is both unpleasant and clinically misleading. Every method below
buys steadiness with lag; the sections differ only in how cleverly they spend that
currency.

### 9.0 Before any filter: the stability gate

The cheapest noise reduction in the pipeline is not a filter at all. `CornerStabilityFilter`
compares this frame's corners with the last frame's, and if **every** corner moved less
than `corner_stability_threshold` (2.0 px), the pose solve is skipped entirely and the
previous pose is reused:

```python
if float(np.max(np.linalg.norm(curr - prev, axis=-1))) > self.threshold:
    ...   # moved — re-solve
return True   # unchanged — reuse the cached pose
```

The point is subtle and worth stating plainly. When the device is genuinely still,
`solvePnP` fed near-identical corners still returns *slightly different* answers each
frame — iterative refinement on noisy input is not a deterministic function of the scene.
That is jitter created by the solver, on top of the jitter already in the image. Reusing
the previous pose eliminates it exactly, at zero cost, with no lag whatsoever, because
nothing has actually changed. Note this gate uses the **maximum** corner motion, not the
mean — one corner drifting is enough to force a re-solve.

### 9.1 EMA — exponential moving average

The default (`filter_type = "ema"`, $\alpha = 0.4$):

$$
\mathbf{y}_t = \alpha\, \mathbf{p}_t + (1 - \alpha)\, \mathbf{y}_{t-1}
$$

**This is an RC low-pass filter.** Discretise $RC\,\dot{y} + y = x$ by the backward
difference $\dot{y} \approx (y_t - y_{t-1})/\Delta t$:

$$
\frac{RC}{\Delta t}(y_t - y_{t-1}) + y_t = x_t
\qquad\Longrightarrow\qquad
y_t = \frac{\Delta t}{RC + \Delta t}\,x_t + \frac{RC}{RC + \Delta t}\,y_{t-1}
$$

which is the EMA with

$$
\boxed{\;\alpha = \frac{\Delta t}{\tau + \Delta t} = \frac{1}{1 + \tau/\Delta t},
\qquad \tau = RC = \frac{1}{2\pi f_c}\;}
$$

Two things follow. First, everything already known about first-order low-pass filters
transfers directly. Second — and this is the connection to make now rather than in §9.3 —
that boxed formula is *literally* `OneEuroFilter3D._alpha`. The One Euro filter is not a
different filter; it is this one, with $\alpha$ recomputed every frame.

**How much noise it removes.** Model the input as $\mathbf{p}_t = \bar{\mathbf{p}} + n_t$
with $n_t$ white noise of variance $\sigma^2$. At steady state, taking the variance of both
sides (the two terms are independent, since $y_{t-1}$ depends only on past noise):

$$
\operatorname{Var}(y) = \alpha^2 \sigma^2 + (1-\alpha)^2 \operatorname{Var}(y)
$$

$$
\operatorname{Var}(y)\left[ 1 - (1-\alpha)^2 \right] = \alpha^2\sigma^2
\qquad\Longrightarrow\qquad
\operatorname{Var}(y) = \frac{\alpha^2 \sigma^2}{2\alpha - \alpha^2} = \frac{\alpha}{2 - \alpha}\,\sigma^2
$$

$$
\boxed{\;\frac{\text{output noise}}{\text{input noise}} = \sqrt{\frac{\alpha}{2-\alpha}}\;}
$$

At $\alpha = 0.4$ that is $\sqrt{0.4/1.6} = 0.5$ — exactly 2× quieter.

**What it costs.** A step input is tracked as $1 - (1-\alpha)^n$, so the response reaches
63 % after

$$
n = \frac{1}{-\ln(1-\alpha)} = \frac{1}{0.511} \approx 2 \text{ frames}
$$

At the 100 fps target that is about 20 ms of lag — imperceptible. So $\alpha = 0.4$ buys a
factor of 2 in noise for 20 ms in lag, which is a good trade. Halving $\alpha$ to 0.2 would
give $\sqrt{0.2/1.8} = 0.33$ (3× quieter) for $1/0.223 \approx 4.5$ frames, 45 ms — the
point at which lag starts to be felt in a reaching game.

### 9.2 Kalman — letting the data set the smoothing

The EMA smooths by a fixed amount forever. The Kalman filter's idea is that the right
amount of smoothing depends on how uncertain the estimate currently is — and that this
uncertainty can be *tracked*, not tuned.

**The scalar case, which is the whole idea.** Suppose you have two estimates of the same
number: a prediction $x^-$ with variance $P^-$, and a measurement $z$ with variance $R$.
§7.4 already derived the best way to combine two independent estimates — inverse-variance
weighting:

$$
x = \frac{\frac{1}{P^-}x^- + \frac{1}{R}z}{\frac{1}{P^-} + \frac{1}{R}}
= \frac{R\,x^- + P^-z}{P^- + R}
$$

Rearranged into the form everyone writes it in:

$$
x = x^- + K\left( z - x^- \right),
\qquad
\boxed{\;K = \frac{P^-}{P^- + R}\;}
$$

and the combined variance is $P = (1 - K)P^-$. **That is the Kalman filter.** The gain $K$
is just the inverse-variance weight wearing different notation. Read it at the extremes: a
perfect measurement ($R \to 0$) gives $K \to 1$, so trust the measurement completely; a
perfect prediction ($P^- \to 0$) gives $K \to 0$, so ignore the measurement. And note that
$K$ *changes over time* as $P^-$ evolves — that is what the EMA's fixed $\alpha$ cannot do.

The multivariate version is the same three statements with covariance matrices, where
"divide by variance" becomes "multiply by an inverse":

$$
\mathbf{K}_t = \mathbf{P}_t^- \mathbf{H}^\top \left( \mathbf{H} \mathbf{P}_t^- \mathbf{H}^\top + \mathbf{R} \right)^{-1}
$$
$$
\mathbf{s}_t = \mathbf{s}_t^- + \mathbf{K}_t\left( \mathbf{z}_t - \mathbf{H}\mathbf{s}_t^- \right)
$$
$$
\mathbf{P}_t = \left( \mathbf{I} - \mathbf{K}_t \mathbf{H} \right) \mathbf{P}_t^-
$$

**Where the prediction comes from.** The state carries position *and* velocity:

$$
\mathbf{s}_t = (x, y, z, v_x, v_y, v_z)^\top
$$

and the prediction step is plain kinematics — position advances by velocity times elapsed
time, velocity is assumed unchanged:

$$
\mathbf{s}_t^- = \mathbf{F}\mathbf{s}_{t-1},
\qquad
\mathbf{F} = \begin{bmatrix} \mathbf{I}_3 & \Delta t\,\mathbf{I}_3 \\ \mathbf{0}_3 & \mathbf{I}_3 \end{bmatrix},
\qquad
\mathbf{P}_t^- = \mathbf{F}\mathbf{P}_{t-1}\mathbf{F}^\top + \mathbf{Q}
$$

$\mathbf{H} = [\mathbf{I}_3 \mid \mathbf{0}_3]$ because the tracker measures position only
— velocity is never observed, only inferred from how position changes. The output is the
first three components of $\mathbf{s}_t$.

**The two knobs.** $\mathbf{Q}$ (`kalman_process_noise`, default $0.01 \cdot \mathbf{I}_6$)
says how much the velocity is expected to change between frames; $\mathbf{R}$
(`kalman_measurement_noise`, default $0.05 \cdot \mathbf{I}_3$) says how noisy the incoming
position is. Only their **ratio** matters for the steady-state gain. Raising $\mathbf{Q}$
means "the hand is unpredictable, trust the measurement" → less smoothing; raising
$\mathbf{R}$ means "the measurement is unreliable, trust the model" → more smoothing.
$\Delta t$ is measured per update from `time.monotonic()`, so frame-rate jitter does not
corrupt the model.

**Why it overshoots at stops.** This is the failure mode to know, because reach-and-hold is
exactly the movement this device measures. The predict step assumes velocity persists. When
the hand stops abruptly, $\mathbf{s}^-$ still carries the old velocity, so the prediction
sails past the true position; the update step pulls it back, but only by the fraction $K$
each frame. For several frames the reported position continues beyond where the hand
actually is, and then creeps back — visible as the cursor overshooting the target and
settling. Raising $\mathbf{Q}$ shortens the overshoot at the price of a noisier hold, which
is the trade the One Euro filter refuses to make.

### 9.3 One Euro — an EMA whose cutoff follows the hand

The problem with everything above is that reach-and-hold has two regimes with opposite
requirements. Holding still needs heavy smoothing (all the motion is noise). Reaching needs
light smoothing (all the motion is signal, and lag is felt directly). A fixed $\alpha$
must compromise.

The One Euro filter (Casiez, Roussel & Vogel) resolves it by *measuring which regime you
are in* and moving the cutoff accordingly. Given §9.1's
$\alpha = 1/(1 + \tau/\Delta t)$ with $\tau = 1/(2\pi f_c)$, all it needs is a rule for
$f_c$.

**Estimate the speed.** Differentiate, then smooth the derivative with a fixed-cutoff EMA
(a raw frame-to-frame difference is far too noisy to steer anything):

$$
\dot{\mathbf{p}}_t = \frac{\mathbf{p}_t - \mathbf{p}_{t-1}}{\Delta t},
\qquad
\hat{\dot{\mathbf{p}}}_t = \alpha_d \dot{\mathbf{p}}_t + (1-\alpha_d)\hat{\dot{\mathbf{p}}}_{t-1},
\qquad
\alpha_d = \frac{1}{1 + \tau_d/\Delta t}
$$

**Open the cutoff with speed:**

$$
s_t = \left\| \hat{\dot{\mathbf{p}}}_t \right\|,
\qquad
f_{\text{cutoff}} = f_{\min} + \beta\,s_t,
\qquad
\alpha_p = \frac{1}{1 + \tau_p/\Delta t}, \;\; \tau_p = \frac{1}{2\pi f_{\text{cutoff}}}
$$

**Then filter the position with that $\alpha_p$:**

$$
\mathbf{y}_t = \alpha_p \mathbf{p}_t + (1-\alpha_p)\mathbf{y}_{t-1}
$$

Still still → $s_t \approx 0$ → $f_{\text{cutoff}} = f_{\min}$ → small $\alpha_p$ → heavy
smoothing. Moving → $s_t$ grows → cutoff rises → $\alpha_p$ grows → smoothing eases and lag
disappears exactly when it would be noticed. Two parameters instead of one, and the second
one buys the regime switch.

> **A number worth checking before trusting this filter.** The shipped defaults are
> `one_euro_min_cutoff = 1.0` Hz and `one_euro_beta = 0.007`, with the input in **metres**.
> A brisk reach runs at roughly $0.5$ m/s, giving
> $f_{\text{cutoff}} = 1.0 + 0.007 \times 0.5 = 1.0035$ Hz — a **0.35 %** change. As
> configured, the adaptive term does essentially nothing and the filter is an ordinary EMA
> at a 1 Hz cutoff, which at 100 fps is $\tau = 0.159$ s and
> $\alpha_p = 1/(1 + 15.9) \approx 0.06$ — far heavier smoothing than the EMA path's 0.4,
> with correspondingly more lag. For $\beta$ to do the job the paper intends on
> metre-scale input it would need to be of order 5–10. This may be deliberate tuning that
> arrived at "smooth EMA" empirically; it is flagged here because the configuration does
> not do what the filter's name suggests, and that is worth knowing before tuning it.

### 9.4 NoOp

$\mathbf{y}_t = \mathbf{p}_t$. Not a filter but a measuring instrument: selecting it
reports the raw noise floor at the cursor, which is what `tools/analyze_jitter.py` needs to
compare §7.1 against §7.2 without a filter masking the difference.

---

## 10. UDP packet — sending to Godot

The filtered 3D position is packed into a UDP datagram:

```
[code: f32, x: f32, y: f32, z: f32]   →   16 bytes, little-endian
```

```python
data = np.append(msg_code, coords).flatten()
data_bytes = struct.pack("<" + "f" * len(data), *data)
self.udp_socket.sendto(data_bytes, self.addr)
```

`code` is a command marker (`2.0` = START, `-99.0` = STOP, `5.0` = RESET) driving Godot's
state machine. The packet goes to whatever address last sent us a message — Godot's address
is learned from its first packet rather than configured.

**Why UDP and not TCP.** TCP guarantees delivery by retransmitting lost packets, which is
precisely the wrong behaviour here. A position that arrives 200 ms late is worse than
useless — it is *wrong*, and it will be followed by a burst of equally stale positions as
the queue drains. At 100 fps a dropped packet costs 10 ms and the next one supersedes it
completely. The pipeline wants the newest sample or nothing, which is also the reasoning
behind `_LatestFrameSlot` on the capture threads: a queue's FIFO semantics are the wrong
fit when the only frame anyone wants is the newest one.

**The watchdog.** Godot sends `CONNECTED` every 100 ms; `run()` exits if no fresh packet
arrives for 3 seconds. Since the tracker is launched by Godot, this is what stops an
orphaned Python process holding the camera open after the game closes.

---

## 11. Godot side — world position to screen pixels

`UDPReceiver` reads the packet and takes `raw_x` and `raw_z` — the X and Z components of
§8's world-frame position.

**Why those two.** `board.py` records that the markers are glued with their printed-up
axis $(+Y)$ aligned to device-up, so the board frame's $Y$ is the vertical. The device
slides on a horizontal surface, which means the movement of interest lives in the $X$–$Z$
plane and $Y$ is nearly constant. Two numbers in, two numbers out.

**The transform.** If `WorkspaceConfig.sensor_calibrated`, a 2D affine map is applied:

$$
\begin{bmatrix} s_x \\ s_y \end{bmatrix}
= \begin{bmatrix} a_{00} & a_{01} & a_{02} \\ a_{10} & a_{11} & a_{12} \end{bmatrix}
\begin{bmatrix} \text{raw}_x \\ \text{raw}_z \\ 1 \end{bmatrix}
$$

**Why affine is the right model here, and no more.** This is a mapping from one plane (the
workspace surface) to another (the screen). Unlike every earlier stage, **no camera is
involved** — the perspective was already inverted back in §6, and what remains is a
correspondence between two flat coordinate systems related by rotation, scale, shear and
offset. That is exactly what an affine map expresses. A full homography (§4.6) would add
two perspective terms that have nothing physical to represent here, and would fit noise
with them.

The 6 unknowns are fit at calibration time from 4 corner samples: the patient parks the
device at each corner of the intended workspace, and each sample contributes 2 equations,
giving 8 equations for 6 unknowns. Overdetermined by 2, so it is a least-squares fit —
`_fit_affine_2d` in `workspace_config.gd` stacks the samples into $\mathbf{A}\mathbf{h} = \mathbf{b}$
and solves the normal equations $\mathbf{A}^\top\mathbf{A}\,\mathbf{h} = \mathbf{A}^\top\mathbf{b}$.

Two spare equations again — the same structural point as §6.2 — which is what makes the
residual of this fit a usable warning that the four corner samples were taken sloppily.

Because this map is fitted from samples produced by §8's expression, it absorbs any
consistent sign or scale convention upstream. That is a convenience and a hazard: a
systematic scale error introduced back in §2 (a mis-measured chessboard square) is absorbed
here too, invisibly, and the cursor still lands where the patient expects while every
number in the recorded CSV is wrong by the same percentage.

---

## Pipeline summary

**Once, offline:**

$$
\text{chessboard photos} \xrightarrow[\text{(§2)}]{\texttt{calibrate\_camera.py}} \mathbf{K}, \mathbf{D}
\qquad
\text{device photos} \xrightarrow[\text{(§7.3)}]{\texttt{calibrate\_board.py}} \texttt{board\_geometry.json}
$$

**Once, at startup:**

$$
\mathbf{K}, \mathbf{D} \xrightarrow[\text{(§3)}]{\texttt{initUndistortRectifyMap}} \texttt{map1, map2}
\qquad
\text{10 stable frames} \xrightarrow[\text{(§8)}]{\texttt{\_maybe\_lock\_origin\_board}} \mathbf{R}_{\text{lock}}, \mathbf{g}_{\text{lock}}
$$

**Every frame:**

$$
\text{raw fisheye} \xrightarrow[\text{(map1, map2, INTER\_LINEAR)}]{\texttt{cv2.remap}} \text{undistorted}
$$
$$
\xrightarrow[\text{(threshold → contour → quad → homography → decode)}]{\texttt{detectMarkers}} \{(\text{id}_i,\; \text{corners}_i)\}
$$
$$
\xrightarrow[\text{(total least squares on each side)}]{\texttt{CORNER\_REFINE\_CONTOUR}} \{\text{refined corners}_i\}
$$
$$
\xrightarrow[\text{(ITERATIVE / SQPNP / IPPE\_SQUARE — §6.5)}]{\texttt{estimate\_board\_pose}} \mathbf{R}, \mathbf{t} \;\; \text{(one pose, all markers)}
$$
$$
\xrightarrow[\text{(dual-camera only — §7.4)}]{\texttt{\_fuse\_board\_poses}} \mathbf{R}, \mathbf{t} \;\; \text{in cam0's frame}
$$
$$
\xrightarrow[\;{}_{\text{cam}}\mathbf{g} = \mathbf{R}\,{}_{\text{board}}\mathbf{g} + \mathbf{t}\;]{\texttt{\_process\_board}} {}_{\text{cam}}\mathbf{g}
\xrightarrow[\;\mathbf{R}_{\text{lock}}^\top(\mathbf{g}_{\text{lock}} - \mathbf{g})\;]{\text{§8}} {}_{\text{world}}\mathbf{p}
$$
$$
\xrightarrow[\text{(EMA / Kalman / One Euro / NoOp — §9)}]{\texttt{filter.update}} \mathbf{y}
\xrightarrow[\text{(struct.pack, sendto)}]{\texttt{\_send\_coordinates}} \text{UDP}
\xrightarrow[\text{(2D affine — §11)}]{\text{Godot}} \text{cursor pixels}
$$

**The thread that runs through all of it.** Every stage's noise contribution adds in
quadrature to the final cursor jitter, and §5.1's

$$
\delta Z = \frac{Z}{p}\,\delta p
$$

is the exchange rate between the pixel world and the millimetre world. One pixel of corner
error is 5.4 mm of depth error with one marker, 2.0 mm with the whole constellation. That
single relation explains why sub-pixel refinement is worth a stage of its own (§5), why
measuring the whole device beats measuring one marker (§7.1), why a second camera helps
(§7.4), and why the measured jitter came out where it did. `diagnose_jitter.py` measures
the noise floors of the first few stages directly, so the chain can be audited rather than
assumed.
