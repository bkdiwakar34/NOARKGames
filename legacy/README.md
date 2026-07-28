# legacy/ — pre-v2 codebase (retired)

The original NOARKGames build, kept for reference only. Nothing here is
referenced by `project.godot`, `app/`, or `v2/`, and the `.gdignore` in this
folder keeps the Godot editor from importing any of it.

| Folder | What it was |
|---|---|
| `Assets/` | art, audio and scene assets for the old games |
| `Games/` | the original game scenes and scripts |
| `Main_screen/` | the original main menu / navigation |
| `Results/` | early progress-reporting screens (last touched 2025-10) |
| `tag_*.png` | printable ArUco marker images used during early bring-up |

Full history is in git — `git log --follow legacy/<path>` still works across
the 2026-07-28 move.

**If any of this ever needs to run again**, its internal `res://` paths point at
the old top-level locations (`res://Games/...`, `res://Assets/...`) and would
need rewriting to `res://legacy/...` first.

Current code lives in `app/` (see [../docs/v1_plan.md](../docs/v1_plan.md));
`v2/` is the frozen fallback that `app/` was copied from.
