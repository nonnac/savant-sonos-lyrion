# savant-sonos-lyrion

Full Sonos music browsing (including Spotify via Spotty) in the Savant Pro app, using
[Lyrion Music Server](https://lyrion.org) as the music engine and Savant's built-in
Squeezebox support, plus TV-input control for Sonos soundbars, all as one Savant component.

```
Savant Pro app ──browse/now playing──▶ Savant host (Squeezebox engine)
                                         │  JSON-RPC + Cometd :9000
                                         ▼
                                Lyrion (this image)
                                 ├─ UPnP/DLNA Bridge plugin ──stream──▶ Sonos
                                 └─ Savant Sonos Bridge plugin ──UPnP :1400──▶ Sonos
                                       (TV input, volume, mute, source feedback)
```

## What's in here

| Path | What it is |
|---|---|
| `docker/Dockerfile` | Builds `ghcr.io/nonnac/savant-sonos-lyrion` on top of `ghcr.io/lms-community/lyrionmusicserver` |
| `docker/apply-patches.sh` | The three Lyrion fixes Savant needs, plus installs the plugin. Fails the build if Lyrion's code changed |
| `lyrion-plugin/SavantSonos/` | Savant Sonos Bridge, a Lyrion plugin that talks to the Sonos directly |
| `savant-profiles/lyrion_sonos-soundbar.xml` | Room profile for a Sonos soundbar: music + TV (eARC) input (`Lyrion` / `Sonos-Soundbar`) |
| `savant-profiles/lyrion_sonos-speaker.xml` | Room profile for a Sonos speaker/amp without TV input (`Lyrion` / `Sonos-Speaker`) |
| `savant-profiles/lyrion_sonos-matrix.xml` | Virtual 16x16 matrix for multi-room grouping (`Lyrion` / `Sonos-Matrix`) |
| `.github/workflows/build.yml` | Builds and publishes the image on push, weekly, or on demand |

### The Lyrion fixes

1. **Cometd subscribe crash.** Savant subscribes on `/meta/subscribe` with a `data` block (old
   SqueezeCenter style). Lyrion 9 crashes in `Cometd/Manager.pm` on these, which leaves the Pro app
   spinning. They are now re-routed to `/slim/subscribe`.
2. **Player ID (optional, off by default).** Savant puts its Cometd client ID where the player MAC
   belongs in its live status subscription, so Lyrion refuses it (`errorNeedsClient` in the log).
   This is harmless: Savant also polls each player's status every second and now-playing comes from
   that. Creating `/config/savant-player.txt` with one player MAC makes the patch map every Savant
   subscription to that player, which is only useful with a single Sonos.
3. **Menu weights.** Some home-menu items (e.g. *Composers*) have their sort weight as a
   string. Savant's host sorts the menu and crashes (`-[__NSCFString objCType]`), restarting the
   component every time you browse. Weights are now always numeric.

### Savant Sonos Bridge plugin

Plain-text endpoints on the Lyrion web port (used by the Savant profile):

```
GET /plugins/SavantSonos/status.txt?mac=<player mac>
    -> SRC:TV|STATE:PLAYING|VOL:30|MUTE:0|PWR:1|
GET /plugins/SavantSonos/cmd.txt?mac=<player mac>&do=<tv|lyrion|off|vol|volup|voldown|mute|join|leave|refresh>[&val=n]
GET /plugins/SavantSonos/cmd.txt?do=rooms&val=<mac1>,<mac2>,...   (matrix room list)
```

- Player MAC → Sonos is read from the UPnP Bridge config (`prefs/upnpbridge.xml`); Sonos IPs are
  found by SSDP.
- `SRC` is `TV` (soundbar on its TV input), `LYRION` (playing the bridge stream), `GROUP`
  (following another Sonos), `OTHER` (Sonos app, AirPlay, Spotify Connect) or `IDLE`.
- `join` makes this Sonos follow another one (`val` = player MAC, or a matrix room number); `leave`
  makes it standalone again.
- When a Sonos that Savant is watching switches to `TV` or `OTHER` on its own, the Lyrion player is
  powered off so it doesn't fight the TV.

## Install

Runs anywhere Docker runs (Linux server, NAS, Raspberry Pi 64-bit, etc.). Use **host networking**:
the UPnP/DLNA Bridge and the Sonos plugin both rely on multicast discovery on your LAN.

### docker run

```bash
docker run -d --name lyrion \
  --network host \
  -e PUID=1000 -e PGID=1000 -e TZ=America/Los_Angeles \
  -v /path/to/lyrion/config:/config \
  -v /path/to/music:/music:ro \
  -v /path/to/lyrion/playlists:/playlist \
  --restart unless-stopped \
  ghcr.io/nonnac/savant-sonos-lyrion:latest
```

### docker compose

```yaml
services:
  lyrion:
    image: ghcr.io/nonnac/savant-sonos-lyrion:latest
    container_name: lyrion
    network_mode: host
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/Los_Angeles
    volumes:
      - /path/to/lyrion/config:/config
      - /path/to/music:/music:ro
      - /path/to/lyrion/playlists:/playlist
    restart: unless-stopped
```

The image is the official `ghcr.io/lms-community/lyrionmusicserver` with the patches and plugin
added, so every option from the official image works the same. Already running the official
image? Point your container at `ghcr.io/nonnac/savant-sonos-lyrion:latest` and keep your existing
`/config`. Settings, plugins and library carry over.

Tags: `latest` (newest good build on Lyrion stable), `lms-<version>` (e.g. `lms-9.1.2`), and the
commit SHA.

### Setup

1. Open Lyrion at `http://<server-ip>:9000` > Settings > Manage Plugins and install
   **UPnP/DLNA Bridge** (and **Spotty** for Spotify). Each Sonos shows up as a player; note its
   player ID (e.g. `bb:bb:12:34:56:01`).
   - **Spotty needs two authorizations** (Settings > Advanced > Spotty for Squeezebox), and Spotify
     Premium. First link the account with your own Client ID from the Spotify Developer Portal. Then
     authorize *playback*: Spotty shows a temporary Spotify Connect device; select it in the Spotify
     app and play anything. Until the second step, the Spotty menu is empty ("Spotify Credentials
     missing"). Restart Lyrion afterwards.
2. Check it: `http://<server-ip>:9000/plugins/SavantSonos/status.txt?mac=<player id>` should
   return something like `SRC:LYRION|STATE:STOPPED|VOL:30|MUTE:0|PWR:0|`.

## Savant (Blueprint)

### Rooms

Add one component per Sonos room: **Sonos-Soundbar** for soundbars with a TV, **Sonos-Speaker** for
everything else (Era, One, Five, Port, Amp, Roam...).

1. *IP* = Lyrion server, *MAC* = that Sonos's player ID from Lyrion.
2. Wire **SPEAKERS** to the zone's speakers. Soundbars: wire the TV's eARC/ARC HDMI port to **HDMI eARC**.
3. Use a TV profile whose audio goes out eARC (a "soundbar build" with the TV speakers removed as
   an audio endpoint), otherwise Blueprint routes TV sources to the TV speakers.
4. In Services, set the music service alias/icon (e.g. "Sonos").

Each room plays its own music with its own now-playing and volume.

### Multi-room (grouping)

Any room can listen to any other room's music, using Sonos's own grouping, so playback stays in sync.
Savant sees a normal distributed-audio matrix, so the Pro app's "add room" and share work as usual.

```
 Room A component                 Sonos-Matrix                  Room B component
 SONOS GROUP OUT ───────────▶ SONOS GROUP IN 1                   
                                    │ (route 1 → 2)
 SONOS GROUP IN  ◀─────────── SONOS GROUP OUT 1                  
                              SONOS GROUP IN 2  ◀──────────── SONOS GROUP OUT
                              SONOS GROUP OUT 2 ────────────▶ SONOS GROUP IN
```

**Setup**

1. Add one **Sonos-Matrix** component (`savant-profiles/lyrion_sonos-matrix.xml`).
   *IP* = Lyrion server. It's virtual: nothing is physically connected.
2. Give every Sonos room a number **N** from 1 to 16. A room uses the **same N** for its matrix
   input and output.
3. For each room, wire in Blueprint:
   - room **SONOS GROUP OUT** → matrix **SONOS GROUP IN N**
   - matrix **SONOS GROUP OUT N** → room **SONOS GROUP IN**
4. On the matrix (State Variables), set **RoomN_PlayerID** to that room's Lyrion player ID
   (Lyrion > Settings > Player, e.g. `bb:bb:12:34:56:01`). Leave unused numbers blank.
5. Check Services for a room: besides its own music service, it should list every other room's
   music service (e.g. "Living Room Sonos" in Kitchen). Upload.

**Example**

| N | Room | Profile | RoomN_PlayerID |
|---|---|---|---|
| 1 | Living Room | Sonos-Soundbar | `bb:bb:12:34:56:01` |
| 2 | Office | Sonos-Soundbar | `bb:bb:12:34:56:02` |
| 3 | Kitchen | Sonos-Speaker | `bb:bb:12:34:56:03` |

**What happens**

- Room B picks room A's service → the matrix routes input A to output B → the plugin makes B's Sonos
  join A's Sonos group (`x-rincon`). Audio comes from one Lyrion stream; Sonos keeps rooms in sync.
- B shows A's now-playing and keeps **its own volume and mute**.
- B turns off, or picks its own music → B's Sonos leaves the group and plays standalone.
- `SonosSource` on B reads `GROUP` while it's following another room.

**Notes**

- A Sonos group always plays in the room that leads it. Turning room A off while B still listens
  keeps A playing (mute A, or start the music from a room that stays on).
- When a room joins, its own Lyrion player may start for a moment before the join (Savant powers the
  room on before routing). The plugin then turns it off.
- Rooms never route to themselves, so Blueprint doesn't create duplicate services.
- Bonded Sonos (subs, surrounds, stereo pairs) aren't rooms; use the room's main player.

### States for triggers

`SonosSource` (TV / LYRION / GROUP / OTHER / IDLE), `SonosTransportState`, `LyrionPower`,
`CurrentVolume`, `CurrentMuteStatus`.

## Known limits

- Lyrion's log shows `errorNeedsClient` each time Savant reconnects (see patch 2). It's expected.
- **No album artwork in the Savant Pro app.** Lyrion serves the art and Savant receives the URL
  (`CurrentArtworkURL`, e.g. `http://<lyrion>:9000/music/<coverid>/cover.jpg`), but the Savant host's
  Squeezebox engine never downloads it: no request reaches Lyrion, and nothing lands in the host's
  `mediaServer/<component>` folder. This looks like a gap in Savant's own Squeezebox
  support (its artwork code reads `MetadataArtworkServerIP` / `mediaServerAddresses.plist`), not
  something this profile can set. The stock Squeezebox profile behaves the same. Now-playing text,
  progress and controls all work. Spotify tracks also return Lyrion's generic radio icon for
  `/music/<coverid>/cover.jpg`. Fixing that is only worth it once Savant fetches art.
- Multi-room limits: see *Multi-room (grouping) > Notes*.
- Lyrion updates: the weekly build rebuilds on the latest Lyrion `stable`. If a patch anchor no
  longer matches, the build fails and `:latest` stays on the last good image. Fix the patch, or run
  the workflow by hand with a pinned `lms_tag`.

## Credits

- `lyrion_sonos-soundbar.xml` is built on the community Savant Squeezebox profile by
  [benumc](https://github.com/benumc).
- Lyrion Music Server and the UPnP/DLNA Bridge by the LMS community.

Lyrion patches and plugin: GPL-2.0-or-later (same as Lyrion).
