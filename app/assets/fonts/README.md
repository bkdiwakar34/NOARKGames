# Font drop-in

The UI uses Godot's default font until these two files exist here, then picks
them up automatically on next launch (runtime-loaded, no import step):

| filename | role |
|---|---|
| `Nunito-Regular.ttf` | all text |
| `Nunito-ExtraBold.ttf` | headings, game names, the score |

Get them from fonts.google.com/specimen/Nunito → Get font → Download all,
then copy the two files from the `static/` folder of the zip. Nunito is
SIL Open Font License — free for any use, no attribution screens needed.
