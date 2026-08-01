# Driver Build Instructions

## Quick Start

```bash
# Build the driver
./build.sh

# Output: build/jriver_media_center.c4z
```

## Prerequisites

### Required

- **Python 3** - Install from [python.org](https://www.python.org/) or via package manager
- **Git** - For downloading the driverpackager tool
- **lxml** (Python library) - Auto-installed by build script via pip

### Optional

- **luacheck** - For Lua syntax validation
  - macOS: `brew install luacheck`
  - Ubuntu/Debian: `apt install lua-check`
  - Rocky/RHEL: `dnf install luacheck`

**Note**: The build script automatically installs Python dependencies (`lxml`) on first run.
No virtualenv or manual pip commands needed.

## Build Commands

| Command | Description |
|---|---|
| `./build.sh` | Build the driver (default) → `build/jriver_media_center.c4z` |
| `./build.sh clean` | Remove build artifacts |
| `./build.sh validate` | Validate Lua syntax (requires luacheck) |
| `./build.sh install` | Install/update the driverpackager tool |
| `./build.sh help` | Show usage |

Plus a driver-level test that needs no controller and no running Media Center:

```bash
lua test-driver.lua     # exits non-zero on failure
```

It stubs the Control4 API and replays MCWS payloads captured verbatim from a live MC
35.0.74 server, covering the browse tree walk, response parsing, playback/UI state and the
exact MCWS request shapes the driver builds. Run it after any change to `driver.lua`.

On first run, the build script downloads the official Control4 driverpackager to
`.driverpackager/` (gitignored).

## Releases

Publishing a GitHub release runs `.github/workflows/release.yml`, which lints, tests, builds
and attaches `jriver_media_center.c4z` to that release. `.github/workflows/ci.yml` runs the
same lint, test and build on every push and pull request, so a broken asset path or a
package-name mismatch fails there rather than on a controller.

Bump `driver.xml`'s `<version>` before tagging. Composer uses that revision to decide whether
an installed driver has an update available; a release whose revision has not moved will
install cleanly but never offer itself as an upgrade.

## Project Layout

```
jriverc4/
├── driver.xml        # Manifest: media_service proxy, screens, connections, properties
├── driver.lua        # Driver logic: MCWS client, browse tree, playback, key/nav forwarding
├── test-driver.lua   # Offline harness: runs driver.lua against captured MCWS payloads
├── tools/            # Icon generation and package verification
├── vendor/feather/   # Vendored Feather icons (MIT) and their licence
├── .github/          # CI and release workflows
├── driver.c4zproj    # Packaging manifest (files to include in the .c4z)
├── build.sh          # Build script (driverpackager wrapper)
├── .luacheckrc       # Lua linter config (Control4 globals whitelisted)
├── module/           # json.lua (Jeffrey Friedl, CC BY 3.0) -- keep its header intact
├── icons/            # Driver, branding, tab and Now Playing icons
├── DESIGN.md         # Architecture and MCWS integration design
├── README.md         # Feature & usage documentation
├── README_BUILD.md   # This file
└── reference/        # Captured MCWS API docs from a live MC install (gitignored)
```

## Versioning

Two version numbers exist and they are **not** the same thing:

- `driver.xml` → `<version>` is the **Composer-facing integer revision**. Bump it whenever
  you want Composer Pro to recognise the driver as an update to an already-installed copy.
- `build.sh` → `DRIVER_VERSION` is the **semantic version used in the output filename only**.

When releasing, update both, plus:

- `driver.xml` → the `Driver Version` property default and `<modified>`
- `driver.lua` → the version string reported via `C4:UpdateProperty("Driver Version", ...)`

## Package filename

The build deliberately outputs `jriver_media_center.c4z` with **no version suffix**, unlike
the sibling drivers. Composer derives a driver's asset namespace from the package filename,
so `controller://driver/jriver_media_center/...` only resolves when the file is named exactly
`jriver_media_center.c4z`. A versioned filename breaks every bundled icon while leaving
remote artwork working, which presents as an icon problem rather than a packaging one. The
release version lives in `driver.xml`'s `<version>`, which is what Composer uses for updates
anyway. `tools/verify-package.py` fails the build if the two ever diverge.

Renaming the package therefore changes the driver's identity: upgrading from a differently
named build means removing the old entry in Composer and adding the driver fresh, rather than
updating in place.

## Asset paths

Everything `driver.xml` points at lives under `www/` in the package, and **both** reference
forms resolve relative to that directory rather than the c4z root:

| Reference in `driver.xml` | Resolves to |
|---|---|
| `<small image_source="c4z">icons/device_sm.png</small>` | `www/icons/device_sm.png` |
| `controller://driver/<name>/icons/device_70.png` | `www/icons/device_70.png` |

Get this wrong and nothing complains: Composer shows its generic driver logo and Navigator
falls back to a default icon, with no error anywhere. `build.sh` runs
`tools/verify-package.py` after packaging to check every reference against the archive.

## Proxy connections

A `media_service` proxy needs a type-7 `AUDIO_SELECTION` end-point in addition to its type-2
`MediaService` connection. Without it the proxy has no room binding, and Navigator silently
never offers the service — the driver loads, communicates, and simply never appears as a
source. There is no error to diagnose from, so check the connection list first when a proxy
is missing from Listen or Watch.

## Trusting the reference material

The `MSP By Numbers` tutorial is a teaching aid, not a specification, and parts of it are
superseded. `UPDATE_MEDIA_INFO` is the clearest example: the tutorial sends
`TITLE`/`ALBUM`/`ARTIST`/`GENRE` with a plain image URL, while the actual specification and
every shipping driver use `LINE1`-`LINE4` with a **Base64-encoded** `IMAGEURL`. The wrong
fields fail silently — Now Playing simply shows a stock icon.

When behaviour disagrees with the tutorial, prefer, in order: the MSP Driver Development
Documentation, a shipping driver (the decrypted Kodi drivers are the closest match to this
one), then the tutorial.

## Autobind IDs

`idautobind` values pair internal connections between proxies of the same driver. They are
**global**, not driver-scoped: reusing a value another installed driver already uses lets
Composer pair the wrong two connections, and the affected proxy silently never appears as a
source. Values here are `51001`-`51004`. Pick a fresh range rather than copying one from a
reference driver: the Kodi drivers use `48001`/`49001`, and any driver reusing those collides
with them wherever both are installed.

## Property types

Composer accepts a limited set of `<type>` values, and an invalid one fails the whole driver
load with a misleading error — `PASSWORD` produces *"Error creating property … Object
reference not set to an instance of an object"* rather than anything naming the type. Types
confirmed working in shipped Control4 drivers: `STRING`, `LIST`, `LABEL`, `RANGED_INTEGER`,
`DYNAMIC_LIST`, `DEVICE_SELECTOR`, `PROXY`. Stick to those unless a new one has been seen in
a driver that actually loads.

## Icons

`icons/` is generated by `tools/make-icons.py` and committed, so the build works from a clean
clone and the artwork can be regenerated or restyled without hand-editing 38 files:

```bash
python3 tools/make-icons.py        # requires Pillow
```

The device and branding marks are original work, deliberately unrelated to JRiver's own
branding so the driver can be published without borrowing their marks. The tab and Now Playing
glyphs are [Feather](https://feathericons.com/) icons (MIT, Cole Bemis), vendored under
`vendor/feather/` along with their licence — the build never reaches the network.

Feather's SVGs use only lines, polylines, circles and paths built from move, horizontal,
vertical and quarter-circle arc commands, so the script rasterises them directly with Pillow
rather than depending on a native SVG library. `libcairo` and friends are not required, so the
icons can be regenerated anywhere Pillow runs.

Palette, glyph mapping and per-glyph stroke weights are constants at the top of the script.
Everything is drawn at 8x and downsampled, which is what keeps the 16px and 20px renders
legible.

## Testing Against the Live Device

MCWS is a plain HTTP API and can be exercised with `curl` against a running Media Center:

```bash
H=http://<mc-host>:52199/MCWS/v1
curl -s "$H/Alive"                                    # version, platform, friendly name
curl -s "$H/UserInterface/Info"                       # UI mode + current view/selection
curl -s "$H/Playback/Zones"                           # zone list
curl -s "$H/Browse/Children?ID=-1&ErrorOnMissing=0"   # browse tree root
curl -s "$H/Browse/Files?ID=<id>&Action=JSON&Fields=Key,Name,Artist,Album"
curl -s "$H/Playback/Info?Zone=<id>&ZoneType=ID"
```

The full endpoint reference as served by the target Media Center build is captured in
`reference/mcws-doc-35.0.74.html` (and a plaintext rendering alongside it). Media Center
serves this itself at `/MCWS/v1/doc` — re-capture it after an MC upgrade rather than
trusting the wiki, which lags the shipping API.

Be aware that `Control/Key` returns `Status="OK"` unconditionally, whether or not the
keystroke had any effect. Verify navigation behaviour by watching the screen, not the
response.
