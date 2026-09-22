# The fridge Pi

What runs on `calendar-pi`, kept here so the wall is rebuildable rather than
only restorable. MagicMirror itself, its config and the third-party modules are
upstream checkouts on the Pi; only what this household wrote lives here.

## MMM-FamilyBrief

The 25vh band above the calendar: the day's summary and weather on the left,
the to-do columns on the right. It renders `brief.json`, which the home server
generates (`brief/`) and pushes over SSH every 15 minutes; the module itself
holds no credentials and talks to nothing but that file.

Install, or update after editing:

```sh
scp pi/MMM-FamilyBrief/MMM-FamilyBrief.{js,css} \
    jacob@calendar-pi.local:~/MagicMirror/modules/MMM-FamilyBrief/
ssh jacob@calendar-pi.local 'curl -s "http://localhost:8080/remote?action=REFRESH"'
```

The `REFRESH` is not optional. MagicMirror serves these files to a Chromium
kiosk that will otherwise keep running the copy it loaded at boot, so an edit
appears to do nothing at all.

### Weather icons

Drawn as inline SVG in `wxIcon()`, not loaded as assets: the Pi has no network
guarantee, and an `<img>` that 404s leaves a broken-image box on a kitchen
wall. The keys it accepts are the vocabulary in `brief/weather.py` — change a
forecast provider there and nothing here needs to know.

The shapes follow the phone's hourly strip but are recoloured for a white
ground, because this panel is dark-on-light where the phone is light-on-dark.
