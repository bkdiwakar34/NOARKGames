# NOARKGames — Dragon Q6A

**This is the Radxa Dragon Q6A repo.** The Raspberry Pi 5 version is a separate
repository, [NOARKGames-pi](https://github.com/bkdiwakar34/NOARKGames-pi), split off on
2026-09-17. Both share history up to the tag `pre-split`; fixes that belong on both
boards are moved across with `git cherry-pick`.

A rehabilitation gaming platform for stroke patients. The patient holds an instrumented device with ArUco markers; a fisheye camera tracks the markers; the resulting 3D position drives a reaching game on a Raspberry Pi. Game difficulty adapts trial by trial to maintain a per-patient target success rate.

Instrument for a PhD study on the causal relationship between success rate and adherence to therapy.

## Stack

- **Game** — Godot 4.5, GDScript. All code in `app/`.
- **Tracker** — Python 3.13+, OpenCV, `rcam`. In `pyscripts/`.
- **Camera driver** — `rcam/`: Rust + Python V4L2 capture for the OV9281, with device-tree overlays.
- **Hardware** — Radxa Dragon Q6A (QCS6490, Linux ARM64) booting from SSD, two OV9281 monochrome fisheye cameras (160° FOV).

## Quick start

```bash
# Install Python deps
python -m venv .venv && source .venv/bin/activate
pip install -e .

# Run game (tracker auto-launched by Godot)
godot --path . --main-scene res://app/ui/main.tscn
```

Main scene: `res://app/ui/main.tscn`. Tracker reads `settings.json` for camera calibration file, filter type, UDP port, etc.

## Documentation

| Doc | Purpose |
|---|---|
| [docs/design.md](docs/design.md) | What the system is, architecture, current adaptive difficulty design (Fitts' Law), key conventions |
| [docs/setup.md](docs/setup.md) | Hardware, calibration procedure, how to run on the Pi, common issues |
| [docs/April-tag tracking.md](docs/April-tag%20tracking.md) | Deep math walkthrough of the tracker pipeline (pinhole, fisheye, PnP, refinement) |
| [docs/v1_plan.md](docs/v1_plan.md) | v1 product plan and build order |
| [docs/todo.md](docs/todo.md) | Open TODOs and pre-deployment checklist |
| [docs/resume.md](docs/resume.md) | Where work last stopped and the next action — read first after a break |
| [CLAUDE.md](CLAUDE.md) | Instructions for Claude Code / AI agents working in this repo |

Earlier codebases (the original mini-game collection, and the `v2/` rewrite that `app/` was copied from) were deleted on 2026-09-15. They are preserved at the git tag `archive-before-cleanup` — `git checkout archive-before-cleanup` restores them.

## License

See [LICENSE](LICENSE).
