# naturMesh

A concept site for an emergency mesh-networking app, plus a small working
prototype of the idea it's built on.

**naturMesh is not a real product.** There's no app, no company, and nothing to
download. The site is a design exercise in what an emergency mesh app could look
like if someone built one.

---

## What's here

| Path | What it is |
|---|---|
| `index.html` | The promotional site. Single file, no build step, no dependencies beyond two webfonts and five hotlinked photos. |
| `prototype/shelternet.py` | A real, working offline LAN chat server. Python 3 standard library only. |

## The site

Open `index.html` in any browser, or serve the folder:

```bash
python3 -m http.server 4000
```

A 520vh sticky stage cross-dissolves three photographs — calm forest, storm
front, aftermath — while a signal readout runs the opposite arc: carrier bars
drop to "no service" just as a mesh of nodes draws itself across the wreckage.

It's `index.html` at the repo root, so GitHub Pages will serve it as-is.
Settings → Pages → deploy from `main` / root.

## The prototype

Unlike the app in the mockup, this part actually runs. It serves a web page and
relays messages between every browser on the same network — no internet, no
accounts, no app install.

```bash
python3 prototype/shelternet.py --net "Sherman County EOC"
```

It prints the URLs it's reachable on. Phones, laptops and Macs open that
address and start talking. Messages go out over Server-Sent Events and come
back in over a plain POST, so there's no WebSocket dependency and it runs on a
stock macOS or Raspberry Pi install. History lives in memory — last 300
messages — and dies with the process. Nothing is written to disk.

Options: `--port` (default 8000), `--host` (default 0.0.0.0), `--net` (the name
shown at the top of the page).

**Scope, honestly:** this is client-server, not a mesh. Everyone has to reach
the one machine running it, so it works exactly as far as the Wi-Fi does. It's
useful when power is up and the WAN is gone — a fibre cut, an ISP outage — and
useless in a grid-down event where the access points die with the building.

---

## Photo credits

All photographs are from [Pexels](https://www.pexels.com/). Pexels images are
released under the Pexels License, and some older ones under CC0 — both allow
free use without attribution, but crediting the photographer is the decent
thing to do.

| Photo | Credit |
|---|---|
| Misty pine forest (opening frame) | [Jaymantri](https://www.pexels.com/@jaymantri/) · [photo 4827](https://www.pexels.com/photo/nature-forest-trees-fog-4827/) · CC0 |
| Spruces above the mist (closing panel) | [Johannes Plenio](https://www.pexels.com/@jplenio/) · [photo 4500037](https://www.pexels.com/photo/forest-in-foggy-morning-in-summer-4500037/) |
| Dark clouds over forested mountain | [photo 14590273](https://www.pexels.com/photo/14590273/) — **photographer unconfirmed** |
| Fallen tree across a park path | [photo 5351109](https://www.pexels.com/photo/uprooted-tree-cut-in-pieces-5351109/) — **photographer unconfirmed** |
| Uprooted pine, Hyrum, Utah | [photo 5494023](https://www.pexels.com/photo/5494023/) — **photographer unconfirmed** |

Three photographer names still need confirming from their Pexels pages. If this
page ever goes anywhere public, check each one first — photographers can change
or remove their work.

Typefaces are [Fraunces](https://fonts.google.com/specimen/Fraunces) (Undercase
Type) and [Archivo](https://fonts.google.com/specimen/Archivo)
(Omnibus-Type), both under the SIL Open Font License.

The logo, wordmark and interface were drawn for this page.

## License

MIT for the code in this repo. The photographs are not covered by it — they
carry their own licenses, listed above.
