# Saber Game Launcher
![](res/saber.ico)

Saber is a free minimal Game Launcher & Frontend with support for running games off of physical devices & keeping a local curated library.

### Features:
* Detects & run games off of external physical deviced like, CDs, USBs, external Hard Drives, SD cards & more.
* Includes customized retroarch built-in for seemless retro game emulation.
* Emulation settings menu (Settings → Emulation, or Emulation Settings in the in-game overlay): per-core options, aspect ratio / integer scaling / smoothing / scanlines / speed, game volume and audio latency, button and key rebinding, and a choice of core per console.
* Mild support for playing retro games directly of their disc.
* SaberFlasher provides an easy method to create a Saber Configuraton for any game, with a hook to downloaded GOG games, create custom game versions with mods, and direct flashing onto external devices.
* A lua plugin system for add custom launcher features yourself


### Off-The-Disc Play Support

| Symbol | Meaning |
| - | - |
| ✅ | Supported |
| ❌ | Unsupported |
| ➖ | Not applicable |

*Real Disc* = an original disc. *Burned Disc* = a burned copy of a disc (an `.iso` / `.cue` image written to CD/DVD). *File Loading* = ROM files on any drive, including a data disc, USB stick, SD card or external hard drive. Cartridge consoles never had discs, so only File Loading applies to them.

| Console | Real Disc | Burned Disc | File Loading | Note |
| - | - | - | - | - |
| NES | ➖ | ➖ | ✅ | `.nes` |
| Master System | ➖ | ➖ | ✅ | `.sms` |
| PC Engine / TurboGrafx-16 | ➖ | ➖ | ✅ | `.pce`; CD games not supported |
| Mega Drive / Genesis | ➖ | ➖ | ✅ | `.md` `.gen` `.smd` |
| Game Boy | ➖ | ➖ | ✅ | `.gb` |
| Game Gear | ➖ | ➖ | ✅ | `.gg` |
| SNES | ➖ | ➖ | ✅ | `.sfc` `.smc` |
| Sega CD / Saturn / 3DO / PC-FX | ❌ | ❌ | ❌ | RetroArch has cores; Saber doesn't load them yet |
| PlayStation | ✅ | ✅ | ❌ | `.cue` / `.bin` / `.iso` files not loaded yet |
| Nintendo 64 | ➖ | ➖ | ✅ | `.n64` `.z64` `.v64` |
| Game Boy Color | ➖ | ➖ | ✅ | `.gbc` |
| Dreamcast | ❌ | ✅ | ❌ | PC drives can't read pressed GD-ROMs; self-boot CD-Rs only, copied to disk on first play |
| PlayStation 2 | ✅ | ✅ | ❌ | `.iso` files not loaded yet |
| Game Boy Advance | ➖ | ➖ | ✅ | `.gba` |
| GameCube / Wii | ❌ | ❌ | ❌ | RetroArch has a core; Saber doesn't load it yet |
| Nintendo DS | ➖ | ➖ | ✅ | `.nds` |
| PlayStation Portable | ❌ | ✅ | ❌ | PC drives can't read real UMDs; burned game discs only |
| Nintendo 3DS | ➖ | ➖ | ❌ | RetroArch has a core; Saber doesn't load it yet |

Only NES, SNES, Game Boy Color and Game Boy Advance ROM loading has been run in the real app; the rest is implemented but untested. RetroArch has no cores for the Switch, PS3, Xbox or later consoles, so they aren't listed.
