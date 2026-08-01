# JRiver Media Center — Control4 Driver Design

How this driver is put together, and why — including the parts of Control4 and MCWS that are
not obvious from either set of documentation.

## Goals

1. **One self-contained `.c4z`.** No helper service, no container, no second config surface.
   The driver talks to MCWS directly.
2. **Two control modes, one driver.**
   - **Listen** — projector off, AVR on. Browse and control music entirely from a Halo Touch
     or other navigator. No screen needed.
   - **Watch** — projector on, Media Center showing Theater View. Drive Media Center's own
     on-screen UI with directions / select / back from the room's remote.
3. **Deliberately minimal on the Watch side.** A video source with output connections and
   control commands — no channel, guide, or tuner semantics.

## Target environment

Verified live against the install this driver is being written for:

| | |
|---|---|
| Media Center | 35.0.74 on macOS, library version 24 |
| MCWS | `http://<host>:52199/MCWS/v1`, **authentication off** |
| Zones | One — "Player", ZoneID `0` |
| Content | Music only |
| Audio path | Mac → AVR |
| Video path | Mac → projector, on only some of the time |

The endpoint reference served by this exact build is captured at
`reference/mcws-doc-35.0.74.html`. Re-capture from `/MCWS/v1/doc` after an MC upgrade;
the public wiki lags the shipping API and blocks automated fetches.

## Architecture

```
┌──────────────┐   proxy 5001 (media_service)   ┌─────────────────┐
│ Halo Touch   │ ◄────── browse / transport ───►│                 │
│ & navigators │                                │  JRiver driver  │       ┌──────────────┐
└──────────────┘   proxy 5002 (media_player)    │   (single .c4z) │◄─────►│ Media Center │
┌──────────────┐ ◄──── nav keys / transport ───►│                 │ MCWS  │  (MCWS API)  │
│ Room remote  │                                └────────┬────────┘  HTTP └──────┬───────┘
└──────────────┘                                         │                       │
                                              HDMI / audio out          HDMI → AVR → projector
```

### Why three proxies

A `media_service` proxy has no route to a room on its own. It is not enough to give it a
type-7 room end-point, and not enough to give it an audio path — both were tried and neither
made it appear in Navigator. It has to bind into a device that owns an AV chain.

The shipping Kodi drivers solve exactly this problem — a browsable music service plus an
on-screen-UI device sharing one physical output — and this driver mirrors their topology:

```
5001 media_service ──LINK_/RF_ (type 1 + 5)──┐
                                             ├──► 5003 avswitch ──► HDMI ──► AVR
5002 media_player  ──audio/video (type 6)────┘
```

The `avswitch` is a virtual amp. It is not user-facing and has no behaviour; it exists so
one physical binding serves both Listen and Watch. Its proxy commands are ignored by the
driver. Capabilities are shared across all three proxies, which is safe here because both
shipping Kodi drivers use the same values (`media_type 2`, `ui_selects_device False`,
`hide_in_media True`, category `media_player`).

### Proxy 5001 — `media_service` (Listen)

Provides the Navigator browse UI, Now Playing, and transport, on top of MCWS's native browse
tree (below).

Alongside its type-2 `MediaService` connection it carries a type-1 `LINK_JRIVER_MUSIC` and a
type-5 `RF_JRIVER_MUSIC` connection into the virtual switcher, exactly as Kodi's music
service binds into Kodi's virtual amp. It claims no room end-point and no audio output of
its own — the AVR owns room selection and volume.

### Proxy 5002 — `media_player` (Watch)

New. `media_player` is the right proxy here: it is what the Apple TV driver uses, it carries
an HDMI output connection so the room can select Media Center as its video source, and it
delivers the full navigation command set — without the channel/guide baggage a `cable` or
`satellite` proxy would drag in.

Commands the proxy delivers, and their MCWS mapping:

| Proxy command | MCWS |
|---|---|
| `UP` `DOWN` `LEFT` `RIGHT` | `Control/Key?Key=Up\|Down\|Left\|Right` |
| `START_*` / `STOP_*` (press-and-hold) | repeat `Control/Key` on a timer while held |
| `ENTER` | `Control/Key?Key=Enter` |
| `CANCEL` | `Control/Key?Key=Backspace` |
| `MENU` / `GUIDE` | `Control/MCC` Theater View jump (Audio / Home) rather than a raw key |
| `PLAY` `PAUSE` `STOP` | `Playback/PlayPause`, `Playback/Pause`, `Playback/Stop` |
| `SKIP_FWD` `SKIP_REV` | `Playback/Next`, `Playback/Previous` |
| `SCAN_FWD` `SCAN_REV` | `Playback/Position` with a relative offset |
| `VOL_UP` `VOL_DOWN` | `Playback/Volume` with `Relative=1` — **off by default**; the AVR owns volume |
| `MUTE_TOGGLE` | `Playback/Mute`; `Set` takes only 1 or 0, so the toggle is resolved against tracked state |
| `ON` | enter Theater View (see below) |
| `OFF` | leave Theater View / optionally `Playback/StopAll` |

`Control/Key` takes a semicolon-delimited sequence, so multi-key macros are a single request:
`Control/Key?Key=Right;Right;Enter&Focus=1`.

**`Focus=1`** brings Media Center to the front and takes focus. On a dedicated HTPC that is
what you want. On a Mac that is also used for other things it is intrusive, so it is exposed
as a driver property rather than hardcoded.

**Caution:** `Control/Key` returns `Status="OK"` regardless of whether the keystroke did
anything. It is not a success signal and must not be treated as one. `Playback/Position` and
`Control/MCC`, by contrast, do report real outcomes.

Declaring `SCAN_FWD, SCAN_REV, DPAD` in `<transports><supported>` is what opts the driver
into the remote's `<<` / `>>` keys and directional pad. This is the mechanism the Apple TV
driver uses, and it is why Watch mode gets seeking that Listen mode cannot.

## Browse: use Media Center's tree, don't rebuild it

The original design reconstructed Artists / Albums / Playlists from `Library/Values` and
hand-built search queries. MCWS already exposes the browse hierarchy that Media Center's own
remote uses, and it is configurable inside MC via Browse Rules.

```
Browse/Children?ID=-1&ErrorOnMissing=0     → child nodes of a location
Browse/Files?ID=<id>&Action=JSON&Fields=…  → files at a node, as JSON
Browse/Files?ID=<id>&Action=Play[&Shuffle=1][&PlayMode=Add|NextToPlay][&ActiveFile=<key>]
Browse/Image?ID=<id>&Width=…&Height=…&Square=1&Format=jpg
Browse/Rules?Type=Remote                   → the rules behind the tree
```

The tree on the target install:

```
-1 ├─ Audio (1) ─┬─ Artist (1000) → artist → album → tracks
   │             ├─ Album (1001)   ├─ Recent (1002)  ├─ Genre (1003)
   │             └─ Composer (1004)  Podcast (1005)  Highly Rated (1006)
   └─ Playlists (4) → Car Radio, Smartlists, Recently Played, Top Hits, Web Media, …
```

Consequences:

- A **generic tree-walker replaces all per-category browse code**. Genre, Composer, Recent,
  Highly Rated and Smartlists come for free, as does anything reconfigured in MC later.
- **No XML parser dependency.** `Action=JSON` returns a plain JSON array that the bundled
  `module/json.lua` parses directly; the remaining `Item name/value` responses are handled by
  the built-in `C4:ParseXml()`. The old PRD's open question about selecting a Lua XML library
  is closed — nothing needs to be added.
- **One endpoint covers every playback action.** Play Album, Shuffle Album, Play Next, Add to
  Queue and Play Track are all `Browse/Files?Action=Play` with different flags.
- `ActiveFile=<key>` starts playback at a specific track *within its album context*, so
  tapping track 5 loads the album and starts at 5 rather than orphaning a single track.
- `Browse/Files` returns everything **beneath** a node, not just its direct children, so
  Play All and Shuffle All work on a branch (an artist, a genre) exactly as on an album.
  They are offered on any node the user has drilled into, but suppressed at the top of a tab,
  where they would mean the entire library rather than the thing just selected.

### Browse ID lifetime

Browse IDs are allocation counters handed out as the tree is traversed. They proved stable
across repeated calls within a session, but `Browse/Reset` exists and MC restarts will
reissue them. The driver therefore:

- caches IDs per session, keyed by the path that produced them;
- re-walks from the root on (re)connect rather than persisting IDs;
- treats a miss as "stale tree", resets its cache and re-walks, instead of surfacing an error.

## Playback state

`Playback/Info` is the poll workhorse:

```
ZoneID State FileKey NextFileKey PositionMS DurationMS Volume VolumeDisplay
ImageURL Artist Album Name
PlayingNowPosition PlayingNowTracks PlayingNowPositionDisplay PlayingNowChangeCounter
```

- `State`: `0` stopped, `1` paused, `2` playing, `3` waiting.
- The Now Playing queue is tappable: entries carry a `queueIndex` and a default action that
  calls `Playback/PlayByIndex` (0-based). Rebuilding the queue via `Browse/Files` would
  restart it instead of moving within it.
- `PlayingNowChangeCounter` changes when the queue changes — poll the cheap info call, and
  only refetch `Playback/Playlist?Action=JSON` when the counter moves. That gives the Now
  Playing screen the **real** queue instead of the fabricated single-item list it shows today.
- Shuffle and repeat are **not** in `Playback/Info`. `Playback/Shuffle` and `Playback/Repeat`
  called with no `Mode` parameter return the current mode, so state is read from MC rather
  than guessed locally.
- `ImageURL` is returned relative (`MCWS/v1/File/GetImage?File=27`) and must be joined to the
  host. Artwork URLs point straight at MC; navigators fetch them directly.

### Why artwork is not proxied through the controller

Navigators fetch album art from Media Center directly, so each one needs a route to it. On a
segmented network that means a firewall rule per navigator, and a navigator without one shows
placeholder icons while the rest of the driver works normally.

Proxying the images through the Director instead was considered and rejected. DriverWorks has
no HTTP server API — only `C4:CreateNetworkConnection` and the `C4:url*` client calls — so it
would mean hand-rolling an HTTP server inside the driver, buffering binary JPEGs through Lua
strings with no streaming, and serving them from the Director. Each item advertises 14 sizes,
so a 200-track list carries 2,800 image entries; funnelling that through a device whose job is
home automation trades a one-line firewall rule for a permanent performance and support
burden. Every shipping music-service driver points navigators at the source instead, which is
also why the images are plain HTTP URLs here.

## Now Playing: progress and seeking

Grounded in Snap One's *MSP Driver Development Documentation OS 3.2.1* and the
`MSP By Numbers/2-NowPlaying` reference driver.

**A progress bar exists and is display-only.** The `ProgressChanged` event carries `offset`
(current position), `length` (total), optional `buffer` (0-100 while buffering) and `label`
(text shown beside the bar). Snap One's sample annotates these as the duration bar, the
elapsed indicator inside it, and the text next to it — so the Halo gets both a visual
playhead and a time string. The event "should not be sent more frequently than once per
second".

Position only arrives as fast as the poll interval, so the driver interpolates: while
playing, `EffectivePosition()` advances the last synced value by wall-clock and a 1Hz timer
re-emits `ProgressChanged`. Every poll re-syncs from `Playback/Info`, so drift cannot
accumulate, and the bar moves smoothly even at a 5-second poll.

**There is no touch-scrub, and it cannot be added.** The MSP proxy's documented command set
is 23 entries and contains no seek, scan or set-position command; `SCAN_FWD`, `SCAN_REV`,
"fast forward" and "rewind" appear nowhere in the documentation. Valid dashboard
`ButtonType` values are only `PLAY`, `PAUSE`, `STOP`, `SKIP_REV`, `SKIP_FWD` and `CUSTOM`.
Nothing in the platform sends a touched bar position back to a driver. This is a Control4
limit, not an MCWS one — MCWS itself supports absolute, percentage and relative seeking.

**The remote's transport keys**, confirmed on hardware:

`<<` and `>>` *do* arrive as `SCAN_FWD` / `SCAN_REV` on the **media_service** binding, even
though neither appears anywhere in Snap One's MSP documentation. The documented command set
is real but not exhaustive, which is why the driver logs every unrecognised proxy command
once rather than discarding it.

Transport reaches the driver by three routes, all sharing one set of implementations:

| Route | Shape |
|---|---|
| Navigator dashboard tap | binding 5001 **with** a `NAVID`, handled as a session command |
| Room's physical buttons | binding 5001 **without** a `NAVID` — only `ROOM_ID`/`DEVICE_ID` |
| Watch mode | binding 5002, `media_player` proxy |

The room-button route is easy to miss: commands with no `NAVID` bypass the Navigator
dispatch entirely. Buttons also report press and release as a pair (`PAUSE`, then
`END_PAUSE` with a `DURATION`); the press acts, and the release only stops a repeat that a
held key started.

Seeking maps to `Playback/Position?Position=10000&Relative=1|-1&Mode=ms`, verified live
(0 → 10000 → 0). Unlike `Control/Key`, this endpoint returns the resulting position, so it
can be trusted as confirmation. Custom on-screen seek buttons were considered and rejected:
they would duplicate physical keys that already exist on the remote.


## UI mode awareness

`UserInterface/Info` is polled alongside `Playback/Info`:

```xml
<Item Name="Mode">3</Item>
<Item Name="InternalMode">-994</Item>
<Item Name="ViewDisplayName">Audio\Artist</Item>
<Item Name="SelectionDisplayName">Example Artist</Item>
```

`Mode` is the `UI_MODES` enum: `0` standard, `1` mini, `2` display, `3` **theater**, `4` cover,
`-1000` no UI. So `Mode == 3` means Theater View is live on the projector.

In Theater View the response also reports **where the cursor currently is** — the view path
and the highlighted selection. Both are surfaced as driver variables so a navigator can show
what is being controlled, and so programming can react.

This drives real behaviour, not just display:

- **`NoUI`** — MCWS playback calls take a `NoUI` flag. Listen-side playback uses `NoUI=1` so
  starting music never pops MC's UI onto a dark projector. Watch-side playback uses `NoUI=0`
  so MC's own UI follows what the room did.
- **Entering and leaving Theater View**, verified live against MC 35.0.74:

  | Action | Call |
  |---|---|
  | Enter Theater View | `Control/MCC?Command=22001&Parameter=0&Block=1` |
  | Theater View → Home | `Control/MCC?Command=22001&Parameter=1&Block=1` |
  | Theater View → Playing Now | `Control/MCC?Command=22001&Parameter=2&Block=1` |
  | Theater View → Audio | `Control/MCC?Command=22001&Parameter=3&Block=1` |
  | Leave Theater View | `Control/MCC?Command=22009&Parameter=0&Block=1` |

  `22001` is `MCC_THEATER_VIEW`; its parameter is the `SHOW_THEATER_VIEW_MODES` enum
  (`0` toggle, `1` home, `2` playing now, `3` audio, `4` images, `5` videos, `6` playlists…).
  **Entry and exit are asymmetric**: `Parameter=0` enters Theater View but does *not* toggle
  back out once there. Returning to Standard requires `22009`. `UserInterface/Show?View=` was
  tested and is *not* the mechanism — it returns `Status="Failure"` for both UI-mode names and
  tree paths.
- **Variable + event** on mode change, so Control4 programming can key off Theater View
  appearing or disappearing.

## Driver properties

| Property | Default | Notes |
|---|---|---|
| JRiver Host | (empty) | replaces Service Host |
| Enter Theater View on Select | On | Watch selection switches MC to Theater View |
| Leave Theater View on Deselect | On | Watch deselection returns MC to the standard view |
| Leave Theater View on Listen | On | Listen selection returns MC to the standard view |
| JRiver Port | 52199 | replaces Service Port |
| Zone | -1 | `-1` = MC's currently selected zone |
| Poll Interval | 2 | seconds |
| Cache TTL | 300 | seconds, browse tree |
| Take Focus on Key | Off | `Focus=1` on `Control/Key` |
| Enter Theater View on Select | On | Watch-side room selection behaviour |
| Handle Volume | Off | leave volume to the AVR unless enabled |
| Username / Password | (empty) | only needed if MC authentication is turned on |
| Debug Mode | Off | |

Authentication is off on the target install, so the `Authenticate` → `Token` flow is built
but dormant: used only when a username is configured, and appended as `&Token=` to image URLs.

## Defects the rewrite eliminates

These were found in the current implementation. Each is resolved structurally rather than
patched, because the code containing them is being replaced.

| Defect | Resolution |
|---|---|
| Shuffle/repeat POSTed with an empty body → always set "off"; state tracked locally and never read back | Read actual mode from `Playback/Shuffle` / `Playback/Repeat` |
| Playlists dropped when `Path` is empty, hiding root-level playlists | `Browse/Children` on the Playlists node; no filtering |
| Search queries unquoted (`[Album]=Example Album`), breaking any multi-word name | No hand-built queries at all — browse by node ID |
| Hard 100-item ceiling from `?limit=100` with `PaginationStyle NONE` | Tree nodes are naturally scoped; paginate within a node when needed |
| Queueing through `Playback/PlayByKey` loses album context | `Browse/Files?Action=Play&PlayMode=Add\|NextToPlay`, which keeps the surrounding album |
| Zone detected once at service start, `Zone: -1` fallback, no runtime control | Zone is a driver property, sent per request with `ZoneType` |
| No auth support | `Authenticate` flow present, dormant unless configured |
| Polls every 2s forever regardless of selection | Poll only while a navigator or room has the device selected |

## Phases

**Phase 1 — build/repo hygiene.** *(done)* Flattened to the repo-root layout used by
`muxlab` / `dmp-bdt310` / `c4-samsung-volume`; `service/` deleted; `build.sh` re-synced with
muxlab's current version; `README_BUILD.md` added; icons committed; `luacheck` clean.

**Phase 2 — standalone Listen driver.** *(done)* MCWS client in Lua, generic browse
tree-walker, TTL cache, direct artwork URLs, real queue from `Playback/Playlist`, shuffle and
repeat read back from MC, zone property. `media_service` proxy only. Tabs are Artists /
Albums / Playlists / More, each resolved to a browse node by name at runtime. Verified by
`test-driver.lua` (45 checks against captured MCWS payloads) and by a live smoke test of
every read-only endpoint the driver calls.

**Phase 3 — Watch mode.** *(done)* `media_player` proxy on binding 5002 with HDMI and room
selection connections, `<transports>` declaring `SCAN_FWD`/`SCAN_REV`/`DPAD`, `Control/Key`
forwarding with press-and-hold repeat, Theater View entry/exit on room selection, `NoUI`
routing keyed off the live UI mode, and volume gated behind a property. Verified live
end-to-end: entering Theater View, walking the cursor with `Down;Down;Right` to
`Audio\\Artist → Various`, jumping home, and exiting back to Standard.

**Phase 4 — hardware validation.** *(done)* Installed in Composer Pro and exercised on a Halo
Touch: browsing, playback, transport keys, queue jumping, Theater View entry and exit, room
selection and AVR power. What that surfaced is recorded in the git history; the recurring
theme was that the MSP tutorial is not a specification, and that shipping drivers are the
better reference.

## Programming surface

Variables are written only on change, because a variable write propagates to every navigator
and can re-trigger programming; rewriting unchanged values on every poll would make
conditionals fire continuously. `SetupVariables` clears the write cache when it re-declares
them, so the first publish afterwards is not suppressed.

Events originate in the poll loop — `Timer.Poll` → `PollNow` → `Playback/Info` →
`ApplyPlaybackInfo` → `PublishState` → `C4:FireEvent` — with no proxy anywhere in the chain,
so they fire regardless of mode or selection. Polling therefore stays at the configured rate
while anything is playing, not only while something is selected: at the idle rate a track
change during unattended playback could be reported up to half a minute late, which would
make the events useless for programming.

`Connected` is inferred from whether polls are answered rather than from any explicit
handshake, which is what makes a silently unreachable Media Center visible to programming.

Driver commands arrive through `ExecuteCommand`, which — unlike `ReceivedFromProxy` — is not
given a binding, because it is not proxy-scoped. Composer lists a driver's programming under a
single device entry of its choosing, but that grouping is cosmetic: the commands act on MCWS
and work whichever proxy is selected, or none. The five transport commands are prefixed
`JRiver` so they are not mistaken for the room-dependent transport the proxies expose.

`Play Path` and `Play Playlist` address nodes **by name** and resolve them through the same
walk the tabs use. Media Center reassigns browse IDs, and a name is what someone writing
programming actually knows.

## Known limitations

- Halo Touch does not render a progress bar for media services, though the driver broadcasts
  one correctly. `list_nowplaying_non_c4` is declared, which is the documented capability for
  getting Now Playing material onto remote-class devices, and it did not change this.
- Authentication is implemented but untested against a server that requires it.

## Verified on hardware

Installed on Control4 OS 3 with a Halo Touch remote, against Media Center 35 on macOS.
Confirmed working: browsing all four tabs, playback, transport keys from the remote
(including `<<` and `>>`, which are undocumented for a media_service), jumping within the
Now Playing queue, Theater View entry and exit, room selection and AVR power, album art in
lists and on Now Playing, the bundled icon set, and automatic binding of all three proxies'
internal links on a clean add.

Resolved along the way, each recorded in the git history:

- A `media_service` cannot reach a room on its own. It has to bind into a device that owns an
  AV chain — the virtual-amp topology the Kodi drivers use.
- `idautobind` values are global, not driver-scoped. Ours were copied from the Kodi driver
  and collided with it. Once unique, all internal links autobind on a clean add — the manual
  binding that was needed earlier was a stale entry holding connections under the old
  colliding IDs, not a limitation.
- Composer derives a driver's asset namespace from the **package filename**, so the `.c4z`
  must be named exactly `<namespace>.c4z`. A versioned filename silently breaks every
  bundled icon.
- Driver assets resolve relative to `www/`, not the package root.
- Transport and dashboard commands arrive with no `NAVID` and dispatch separately from
  Navigator session commands.
- `UPDATE_MEDIA_INFO` takes `LINE1`..`LINE4` with a Base64 `IMAGEURL`, not the tutorial's
  `TITLE`/`ALBUM`/`ARTIST`.

## Open questions

1. **Library scale.** Everything above was exercised against a two-album library. The browse
   cache ceiling and browse responsiveness have not met a full import.
2. **Authentication** is implemented against the documented `Authenticate` endpoint and
   verified as far as the token round-trip, but has never run against a server that requires
   it.
3. **No progress bar on Halo Touch.** The driver broadcasts `ProgressChanged` correctly and
   `list_nowplaying_non_c4` is declared, which is the documented capability for getting Now
   Playing material onto remote-class devices. Halo appears simply not to render one for
   media services. Other Navigator types are untested.
