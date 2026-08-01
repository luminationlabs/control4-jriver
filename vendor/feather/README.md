# Feather Icons

The tab and Now Playing glyphs are from [Feather](https://feathericons.com/) by Cole Bemis,
used under the MIT License (see `LICENSE`). Only the icons this driver renders are vendored,
so the build does not reach the network.

`tools/make-icons.py` rasterises them: `currentColor` is replaced with the driver's palette,
the viewBox is padded, and the stroke is thickened slightly so the glyphs hold together at
the 70px and 140px sizes Navigator asks for.

| Driver icon | Feather source |
|---|---|
| `tab_artists` | `user` |
| `tab_albums` | `disc` |
| `tab_playlists` | `list` |
| `tab_more` | `more-horizontal` |
| `np_shuffle` | `shuffle` |
| `np_repeat` | `repeat` |
