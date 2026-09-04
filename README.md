# PS1Sim

A native macOS PlayStation 1 front-end. Smooth SwiftUI interface, Metal rendering,
a cover-art library you import into once, real save states, and keyboard controls.

![status](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)

## What this is, honestly

PS1Sim is the **application** — library, renderer, audio, input, save states,
packaging. The **emulation** itself is done by [pcsx_rearmed](https://github.com/libretro/pcsx_rearmed),
a mature libretro core that PS1Sim loads at runtime.

That split is deliberate. A from-scratch PS1 core — R3000A CPU with a dynamic
recompiler, GTE, the GPU's rasteriser and its quirks, SPU with reverb, MDEC video
decoding, CD-ROM subchannel timing — is a multi-year project, and a half-finished
one boots nothing. Building the front-end on a proven core means your games
actually run, today, with accurate timing and working memory cards.

## Install

Download the DMG from [Releases](../../releases), drag **PS1Sim** to Applications,
then clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/PS1Sim.app
```

The build is ad-hoc signed rather than notarized (notarization needs a paid Apple
Developer account), so macOS blocks it until you run that command. You can also
right-click the app and choose **Open** the first time.

## First run

Open **Settings** (⌘,) and complete two steps. The library shows an orange banner
until both are done.

**1. Install the emulator core.** Press **Download Core** to fetch
`pcsx_rearmed_libretro.dylib` from `buildbot.libretro.com`, the official libretro
build server. PS1Sim clears its quarantine flag and ad-hoc signs it so macOS will
load it. If you already have a core, use **Choose Core File…** instead.

**2. Add a PlayStation BIOS.** This is the ~512 KB firmware from a real PS1 —
the boot screen, disc check, and memory-card manager that games call into. It is
Sony's copyrighted code and cannot be distributed, so you dump it from a console
you own. Drop `scph5501.bin` (US), `scph5502.bin` (EU) or `scph5500.bin` (JP)
into the system folder via **Add BIOS File…**.

## Adding games

Press **Import Game** (⌘I) or drag disc images onto the window. Supported:
`.cue`, `.chd`, `.pbp`, `.m3u`, `.iso`, `.bin`, `.img`, `.exe`.

Games are referenced where they sit — importing records a path, it does not copy
your multi-gigabyte disc images. Each game becomes a tile on the home screen;
double-click to play. A bare `.bin` with no sibling `.cue` gets one generated
automatically.

**Multi-disc games.** Select every disc at once in the import dialog — or drag
them in together — and PS1Sim recognises names like `Game (Disc 1).cue` /
`(Disc 2)`, `[Disk 2]`, `CD2` and `- disc_1`, then writes a `.m3u` playlist and
adds one tile for the whole game. When the game asks for the next disc, use the
**Discs** menu in the control bar; it works the tray exactly as a player would
— eject, change, insert. Importing the discs one at a time gives you separate
tiles instead, with no way to swap; a hand-written `.m3u` also works.

**Covers.** Right-click a tile → **Cover** to choose an image, paste one from the
clipboard, or just drag an image file onto the tile. Tiles are square, matching a
PlayStation jewel-case insert, and covers fill them edge to edge. For art that is
not square, **Show Whole Cover** fits it inside the tile over a blurred copy of
itself rather than cropping. Images are re-encoded to PNG at 1024px — a 4000px box
scan would slow the grid down for no visible gain.

**Converting to CHD.** Right-click a game → **Convert to CHD…** roughly halves the
size of a `.cue`/`.bin` with no loss of quality, and the library entry follows the
new file, keeping its cover, play time and save states. This needs `chdman` from
MAME, which PS1Sim does not bundle:

```bash
brew install rom-tools
```

The original disc image is never deleted — that is your call.

**PS1Sim ships no games and no BIOS.** Dump the discs you own with a USB optical
drive (`cdrdao` on macOS, ImgBurn on Windows) to get `.bin`+`.cue` pairs.

## Saving

Two independent systems, both real:

- **Memory cards.** The in-game save menu writes to a virtual memory card in
  `~/Library/Application Support/PS1Sim/saves/`, named after the game's serial
  (`SLUS-00662_1.mcd`). Two cards are provided, as on real hardware, and the
  format is the one DuckStation and ePSXe read, so cards move between emulators.
  This is the save the game itself knows about. The card is written to disk when
  the game shuts down, which happens whether you leave for the library, close
  the window, or quit with ⌘Q — but not if you force-quit.
- **Save states.** Eight slots per game, snapshotting the entire machine —
  ⌘S saves slot 1, ⌘L loads it, and the **States** menu covers all eight.
- **Resume where you left off.** On by default. Leaving a game writes a state
  automatically and reopening it restores that point. It uses its own file, so it
  can never overwrite one of the eight numbered slots. Turn it off in
  Settings → Video → Sessions.

Settings → **Memory Cards** shows every card, how many of its 15 blocks are in
use, the saves on it by name, and can make a timestamped backup of any card.

## Controls

A DualSense, DualShock 4 or Xbox controller works as soon as macOS pairs it — no
setup, no mapping, and it can be used alongside the keyboard. Face buttons follow
physical position, so the bottom button is Cross on any pad. Settings → Controls
shows what is connected.

| Action | Key |
|---|---|
| D-Pad | Arrow keys |
| ✕ / ○ / ▢ / △ | X / C / Z / S |
| L1 / R1 | A / D |
| L2 / R2 | Q / E |
| L3 / R3 | R / T |
| Start / Select | Return / Right Shift |
| Left analog stick | I / J / K / L |
| Pause | P |
| Fast-forward | Hold Tab |
| Save / load state slot 1 | ⌘S / ⌘L |
| Reset console | ⌘R |
| Full screen | ⌘F |
| Back to library | Esc or ⌘W |

Every button and stick direction is rebindable in **Settings › Controls** — click
a binding, press the key you want.

### On-screen reminder

A compact control card sits in the top-right corner while you play, so you are
not memorising a table. It reads your live bindings, so rebinding a key updates
the card too. It dims after twelve seconds to stay out of the way, brightens when
you hover it, and **H** toggles it entirely (also the keyboard button in the
control bar). The choice is remembered between sessions.

## Video options

Smooth (bilinear) scaling, integer scaling that snaps to whole multiples of the
native resolution, and optional CRT scanlines. The picture is always letterboxed
to the game's aspect ratio.

## Building from source

Requires macOS 13+ and the Xcode command line tools.

```bash
swift build -c release          # binary only
scripts/build_app.sh 1.0.0      # universal .app + DMG in ./dist
```

The build script compiles arm64 and x86_64 separately and `lipo`s them, so a full
Xcode install is not required. The app icon is rendered from code by
`scripts/make_icon.swift`, so the repo carries no binary assets.

### Cutting a release

Push a tag and GitHub Actions builds and publishes the DMG:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

To ship a core inside the app instead of downloading it, drop the `.dylib` in
`packaging/cores/` before building — it is bundled and adopted on first run.
Check the core's licence before redistributing it.

## Architecture

| File | Role |
|---|---|
| `Sources/CLibretro/` | Minimal libretro ABI header, plus a varargs log shim Swift cannot express |
| `Core/LibretroCore.swift` | dlopen bridge: environment callbacks, pixel-format conversion, state serialization |
| `Core/EmulatorSession.swift` | `EmulationRunner` owns the emulation thread and core; `EmulatorSession` is its main-actor face |
| `Core/AudioOutput.swift` | Ring buffer feeding `AVAudioSourceNode` |
| `Core/Input.swift` | Keyboard and controller → DualShock mapping |
| `Core/Gamepad.swift` | GameController.framework bridge, feeding the same `InputState` |
| `Core/ChdConverter.swift` | Drives `chdman` to convert disc images to CHD |
| `Library/MemoryCard.swift` | Reads the PS1 card directory: blocks used and saves present |
| `UI/MetalVideoView.swift` | Runtime-compiled Metal shader drawing the framebuffer |
| `UI/LibraryView.swift` | Cover grid, import, search |
| `UI/EmulatorView.swift` | In-game chrome and key handling |
| `Tools/core-probe.c` | Headless probe printing the core's controller ids and option values |

Core options and controller ids are not guessed. `Tools/core-probe.c` dlopens the
core and prints exactly what it advertises:

```bash
clang -o /tmp/probe Tools/core-probe.c
/tmp/probe ~/Library/Application\ Support/PS1Sim/cores/pcsx_rearmed_libretro.dylib
```

Frame pacing runs on the wall clock, nudged by how full the audio ring buffer is,
so video stays locked to the sound card rather than drifting against it.

## Where your data lives

```
~/Library/Application Support/PS1Sim/
├── cores/      emulator core
├── system/     BIOS images
├── saves/      memory cards
├── states/     save states, one folder per game
├── artwork/    cover art you picked
└── library.json
```

## Legal

PS1Sim contains no Sony code, no BIOS, and no games. You supply a BIOS dumped
from hardware you own and disc images of games you own. Emulator software is
lawful; downloading BIOS images or games you do not own is not.

"PlayStation" is a trademark of Sony Interactive Entertainment. This project is
not affiliated with or endorsed by Sony.

## License

PS1Sim's own source is [MIT licensed](LICENSE).

The emulator core it runs, PCSX-ReARMed, is GPL and is **not** bundled or
redistributed here — the app downloads it at runtime, on your instruction, from
libretro's own build server. That separation is deliberate: linking it into the
shipped binary would place this whole project under the GPL.
