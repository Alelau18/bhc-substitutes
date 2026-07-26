> [!NOTE]
> **This is a fork.** The upstream project is
> [Zunawe/bhc-substitutes](https://github.com/Zunawe/bhc-substitutes); everything
> below is theirs. The only change here is to the **mGBA** connector, which has
> been patched so that **loading a different ROM mid-session works** — no
> reloading the Lua script, no restarting the emulator. The client re-detects the
> game; reconnect to the multiworld server (`/connect`) and items keep flowing.
> (Stock Archipelago drops the server connection when the ROM changes and waits
> for a manual reconnect — that part is client-side, not something a connector
> can fix.)
>
> The mesen2 and pj64 connectors are untouched. See
> [`mgba/README.md`](mgba/README.md) for what was fixed. These changes are
> intended to go upstream.

[Archipelago](https://archipelago.gg/)'s BizHawk Client communicates with
[BizHawk](https://tasvideos.org/Bizhawk) by connecting to a Lua script that
runs in the emulator. The client makes a few BizHawk-specific assumptions, but
it's possible to make other connectors that pretend to be the BizHawk Lua
script.

Each directory in this repository contains instructions and resources for using
the corresponding emulator.

In all cases, you will still need to open BizHawk Client, but you can
substitute the emulator on the other side with one of these. If you want
Archipelago to stop autolaunching BizHawk with BizHawk Client, you can modify
your `host.yaml` file's `bizhawkclient_options` entry. Setting `rom_start` to
`false` will disable launching the emulator. Setting `rom_start` to be a path
to an emulator will make Archipelago try to open your patched ROMs in that
program. Though, this is a universal setting, and not a per-system one. So it
might end up trying to open an NES game in mGBA if you do that.

> [!IMPORTANT]  
> Apworld developers and modders may not intend to support emulators or
> connectors other than BizHawk. These substitutions may not be perfectly
> 1-to-1 in terms of functionality and compatibility, and emulators in general
> may have differing behavior on the same game. If you encounter a problem and
> report a bug or ask for help for a game, make sure to be explicit about your
> use of an alternative emulator.
