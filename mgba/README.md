# mGBA
- **Consoles**: GB, GBC, GBA
- **Platforms**: Windows, Mac, Linux
- **Notes**:
  - Requires mGBA 0.10.0 or newer, but you might as well use the latest version.
  - **This fork's connector supports swapping ROMs without restarting anything.**
    See below.
- **Instructions**:
  1. Download `connector_bizhawkclient_mgba.lua` either by opening the file in GitHub and clicking the "Download raw file" button or by downloading the repo and extracting the file.
  2. Put the Lua script in `Archipelago/data/lua/`.
  3. Open your ROM in mGBA.
  4. In mGBA, go to `Tools > Scripting...` in the menu. Then in the newly opened scripting window, go to `File > Load script...`.

## What this fork fixes

On the stock connector, loading a second ROM in a running mGBA session goes wrong
in three escalating ways, and the usual workaround is to reload the Lua script or
restart everything. This fork fixes all three, plus two ways the connector could
stop listening entirely.

| symptom | cause |
|---|---|
| mGBA crashes on a same-platform swap | memory domain handles were cached across ROM loads, outliving the core they belonged to |
| "No handler was found for this game" | `cart0:size()` reports mGBA's `0x800000` placeholder after a swap, so size-based game detection fails |
| connected and authenticated, but no items arrive | WRAM is described with DMG geometry after a swap, so reads land in the wrong bank and every guard silently fails |
| connector stops listening after a client disconnect | the client handle was never cleared on either the read or the socket-error path, and `tick()` only reopens the listener while it is `nil` |
| connector stops listening after a failed setup | `create_server()` published a socket before bind/listen succeeded, so a failed attempt was never retried |

The second and third symptoms come from an mGBA defect —
[mgba-emu/mgba#3640](https://github.com/mgba-emu/mgba/issues/3640), fixed for
0.11.0 — where memory block descriptors are snapshotted before the core's first
reset. The ROM size fix sidesteps the descriptor by asking `emu:romSize()`,
which is correct on every version; the WRAM proxy detects the stale geometry and
passes healthy sessions through untouched. The crash and the two listener
symptoms are bugs in the connector itself — cached handles and socket lifecycle
— and would occur on any mGBA version.

Tested on mGBA 0.10.5 (Linux) against a live multiworld: two Game Boy Color slots
of one seed, swapped mid-session, with items delivered after the swap and no
script reload. Server re-authentication after the swap was driven by a local
BizHawkClient patch; on stock Archipelago, reconnect manually with `/connect`.
Windows/Mac and GBA titles are untested here.
