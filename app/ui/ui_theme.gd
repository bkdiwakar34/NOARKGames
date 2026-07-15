# v1 design-system constants (docs/v1_plan.md §3). Consumers use
#   const UITheme := preload("res://app/ui/ui_theme.gd")
# (deliberately not class_name: that needs an editor scan, and the Pi runs CLI-only.)
# Every screen reads colors
# and sizes from here so the whole look can change in one place. Meaning is
# never carried by color alone: catch/miss also differ in shape and sound.

const BG_TOP      := Color(0.96, 0.94, 0.91)   # warm cream, top of gradient
const BG_BOTTOM   := Color(0.88, 0.83, 0.76)
const ACCENT      := Color(1.0, 0.55, 0.05)

const TEXT_DARK   := Color(0.22, 0.10, 0.02)
const TEXT_SOFT   := Color(0.40, 0.20, 0.04, 0.85)
const CARD        := Color(1.0, 0.88, 0.38, 0.97)

const SUCCESS     := Color(0.20, 0.75, 0.25)   # catch: bright, fast, upward
const MISS        := Color(0.55, 0.55, 0.60)   # miss: soft, brief, downward

const STAR_FILLED := Color(1.0, 0.78, 0.10)
const STAR_EMPTY  := Color(0.45, 0.42, 0.38, 0.5)

const FONT_HUGE   := 64   # headings / big numbers
const FONT_LARGE  := 28   # everything else patient-facing
