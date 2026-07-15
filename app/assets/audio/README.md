# Audio drop-in

Put real audio files here to replace the synthesized placeholders — no code
change, no Godot import step needed; they're picked up on the next launch.

| filename | used for | notes |
|---|---|---|
| `music.ogg` | background music loop | use .ogg — it loops seamlessly |
| `catch.ogg` / `catch.wav` | target caught | short, bright, rising |
| `miss.ogg` / `miss.wav` | target expired | short, soft, falling — gentler than catch |
| `star.ogg` / `star.wav` | each star filling | short chime; pitch is raised per star in code |

Anything missing here falls back to the synthesized version in
`app/platform/audio_manager.gd`. Volumes are the `volume_db` lines there.

Licensing: use CC0/public-domain sources (e.g. kenney.nl, opengameart.org
filtered to CC0) so the research device carries no attribution obligations.
