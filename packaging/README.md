# Direct-download installer

The DMG uses a 720 × 480 Finder window, a Retina background, the real app icon,
and an Applications shortcut. The app is not launched during packaging.

Generate the background after changing the shared scene artwork:

```sh
swift script/render_installer_art.swift "$PWD" "$PWD/packaging/dmg-background.png"
```

Install layout dependencies into a separate environment:

```sh
python3 -m venv .build/dmg-tools
.build/dmg-tools/bin/pip install -r packaging/requirements.txt
```

Package a previously exported, Developer ID–signed and notarized app:

```sh
DMG_PYTHON=.build/dmg-tools/bin/python script/package_dmg.sh \
  '/path/to/Git Island.app' '/path/to/Git-Island.dmg'
```

The normal path requires valid signing, Gatekeeper assessment, and a stapled
app ticket. It never signs or uploads anything. Sign and notarize the resulting
DMG, staple its ticket, and test a quarantined browser download before publishing.
Preserve the app's bundled GPL license and third-party notices.

For a local visual study only, use `--preview` with a Debug bundle and an output
name containing `Preview`. This deliberately accepts unsigned local builds,
labels the volume as an installer preview, and must never be published as a release.
The script refuses to overwrite an existing DMG and detaches its temporary volume
before cleanup. The layout is written through ds_store/mac_alias; no Finder
Automation permission is required.

Native onboarding keeps the existing authorization and verification state machine.
The shared artwork is bundled locally, adds no network requests, and has its
attribution in THIRD_PARTY_NOTICES.md. Its static artwork and reduced-motion-aware
step transitions are independent of the animated website.
