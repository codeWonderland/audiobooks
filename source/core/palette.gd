extends Node
## Central colour palette for the app, mirrored by the global Theme resource
## (assets/theme/default_theme.tres). Registered as the "Palette" autoload so
## code that styles controls dynamically (e.g. the blurred player background)
## uses the same values as the theme.

const BG_DEEP := Color("0b141f")      # window background
const BG_PANEL := Color("141f2d")     # cards, sidebar, panels
const BG_ELEVATED := Color("1b2838")  # hovered / raised surfaces
const BORDER := Color("29394d")       # subtle outlines (pills, dividers)

const ACCENT := Color("f5a63d")       # Audible-style orange (slider, active)
const ACCENT_DIM := Color("c9832f")

const TEXT := Color("edeff2")         # primary text
const TEXT_MUTED := Color("8a98a8")   # secondary text
const TEXT_FAINT := Color("5c6a7a")   # tertiary / disabled

const TRACK := Color("2a3a4d")        # slider unfilled track
