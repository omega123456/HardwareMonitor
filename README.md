# HardwareMonitor

A low-CPU hardware monitor for the macOS 26 menu bar on Apple Silicon. One status item with five columns, each a glyph and two stacked values:

| Column | Top | Bottom |
|---|---|---|
| CPU | usage % | hottest core temperature |
| GPU | usage % | hottest temperature |
| Memory | used % | memory-pressure bar |
| Power | total system draw (W) | battery power (W); a bolt on the glyph while the battery charges |
| Disk | free | total |

- **Colour only for state.** Normal is neutral. Memory turns amber at macOS's "warning" pressure and red with a `!` at "critical". Temperatures warn at 85 °C and are critical at 95 °C; disk warns below 15 % free and is critical below 5 %.
- **Missing values** show a dim "—"; the item never changes width.
- **Hover (300 ms) or left-click** opens a panel with a tile per reading (2-minute sparklines and peaks, temperatures, Super/Efficiency and Performance clock speeds, the memory-pressure gauge, used and swap, disk used and total, a power breakdown) and the top 8 processes by CPU and by memory. It never takes the keyboard; it closes 400 ms after the pointer leaves it and the item, on a click elsewhere, a Space change, a display change, or sleep and lock. A left click toggles it.
- **Right-click or ⌃-click** opens HardwareMonitor's own menu (Launch at Login, Automatic Updates, Check for Updates…, Quit).

HardwareMonitor is **read-only**: it never changes system state, has no settings window and sends no notifications. It is a menu bar agent app with no Dock icon, built for a minimal footprint: one 1-second tick, events instead of polling for memory pressure and power changes, a redraw only when the drawn image changes, and nothing at all while the Mac sleeps, the displays are off or the screen is locked. The process lists and clock speeds cost nothing while the panel is closed: they run only while it is open. It is for personal use only: self-signed, not sandboxed, not notarized.

Requirements: an Apple Silicon Mac on macOS 26.

## Install

1. Download the latest `HardwareMonitor-X.Y.Z.dmg` from [Releases](https://github.com/omega123456/HardwareMonitor/releases).
2. Open it and drag **HardwareMonitor** to **Applications**.
3. Open `/Applications/HardwareMonitor.app`. The app is self-signed and not notarized, so macOS blocks the first launch: go to **System Settings → Privacy & Security**, click **Open Anyway** next to the HardwareMonitor message, and confirm. (Or clear the quarantine flag once: `xattr -dr com.apple.quarantine /Applications/HardwareMonitor.app`.)
4. Optional: right-click the menu bar item and turn on **Launch at Login**.

Installed copies check for updates every hour and update themselves (turn this off with **Automatic Updates** in the right-click menu, or use **Check for Updates…**). Updates are only installed when they are signed with the same "HardwareMonitor Local Signing" identity.

To uninstall, quit it from the right-click menu and move `/Applications/HardwareMonitor.app` to the Bin.

## Usage

- **CPU:** usage is the busy share of all cores over the last 1 s; the temperature is the hottest of the chip's CPU sensors (SMC), read every tick.
- **GPU:** the GPU's own "Device Utilization %"; the temperature is the hottest GPU sensor.
- **Memory:** Activity Monitor's "Memory Used" as a share of physical memory. The bar is macOS's memory-pressure level (fuller means more pressure) in the pressure colour.
- **Power:** the top line is what the whole Mac draws. The bottom line is the battery's power, what flows into the battery while it charges (with a bolt on the glyph), the small trickle when it is held at its limit (no bolt), a dim "—" on battery and on a Mac without a battery. The charger's input stays in the panel's "Adapter in" row. Below 10 W one decimal is shown (`4.2W`).
- **Disk:** the boot volume's free space as Finder counts it (purgeable space included) over its total, in decimal units like Finder (`412G`, `1.2T`).
- **VoiceOver** reads the whole summary from the menu bar item, for example "CPU 38 percent, 61 degrees. GPU 12 percent, 54 degrees. Memory 72 percent, normal pressure. Power 14 watts, on battery. Disk 412 gigabytes free of 926".
- **The panel** refreshes in place every 1 s (tiles, processes and clocks):
  - **Top by CPU** runs `/bin/ps -Aceo pid,pcpu,comm -r`; 100 % is one core, so values above 100 % are possible. **Top by memory** runs `/usr/bin/top -l 1 -o mem -n 8 -stats pid,command,mem` (GB, 1024³ as Activity Monitor). Rows are raw processes (helpers aren't merged), named after the app when there is one; `top` cuts names to 16 characters. A row only moves when another beats it by 10 % or one display unit, so the lists don't jitter. `top` takes about 1.6 s, so the memory list says "Measuring…" for that long after opening and refreshes about every 2 s; while the panel is open it keeps about one core busy.
  - **Clock speeds** come from IOReport and the chip's DVFS tables: all cores of a type averaged by the time spent at each speed (a parked core counts as 0), raised to the type's lowest speed. M5 Pro/Max show "Super" and "Performance"; chips without super cores show "Efficiency" and "Performance". The first second after opening reads "Measuring…".
  - On a short screen the lists show 5 rows ("5 of 8"); if even that doesn't fit, the process tile is left out and `ps`/`top` aren't run. The panel never scrolls.
  - A dim "Stale · N s ago" footer appears only if the readings fall more than 6 s behind.
- **VoiceOver** reads each panel tile and each process list as one sentence, for example "Top by CPU. npm exec ccstatusline at latest, 70 percent. …".
- **Increase Contrast** draws the dim lines at full strength in the menu bar and stronger in the panel; **Reduce Transparency** makes the panel solid; **Reduce Motion** turns off its fade.

## Cost

The budget is below 0.25 % of one core averaged over 10 minutes (the change in Activity Monitor's "CPU Time", or `ps -o time`, over 600 s), and below 40 MB of memory. The per-tick syscall cost on the owner's M5 Pro is about 4–7 ms every 1 s (25 temperature keys and 3 power keys from the SMC, plus a few Mach and IOKit calls).

## Development

Building needs the Swift 6.3 Command Line Tools (Xcode only for the tests).

### One-time setup (per Mac)

1. **Create the signing identity.** Run this in **Terminal.app**, not through Claude Code:
   ```sh
   ./scripts/make-cert.sh
   ```
   It creates the self-signed "HardwareMonitor Local Signing" code-signing identity in your login keychain. It asks for your login keychain password (hidden input) and shows a system dialog to trust the certificate. The updater only installs downloads signed with this same identity. The script is safe to re-run: it exits if the identity already exists. Check the result with:
   ```sh
   security find-identity -v -p codesigning
   ```
   Its SHA-1 (`security find-certificate -c "HardwareMonitor Local Signing" -Z`) is pinned in `.github/workflows/release.yml`.
2. **Release secrets** (only for publishing releases), on `omega123456/HardwareMonitor`: `APPLE_CERTIFICATE` (the identity exported as a base64 `.p12`), `APPLE_CERTIFICATE_PASSWORD`, `KEYCHAIN_PASSWORD` and `RELEASE_CLEANUP_TOKEN`.

### Build and run a development copy

A local build is a separate development copy, **HardwareMonitor Dev**, so testing never touches production:

```sh
./scripts/build-app.sh
```

The script does the following:
1. Builds in debug mode. Debug builds compile in the dev-only behaviour: no update checks, a "DEV" label at the left of the menu bar item, a version row in the menu, and the event log in its own `HardwareMonitor Dev` folder.
2. Assembles `.build/HardwareMonitor Dev.app` with bundle ID `local.hardwaremonitor.dev` and executable `HardwareMonitorDev`, and signs it with "HardwareMonitor Local Signing". Settings and Launch at Login are kept separately from production, because they belong to the bundle ID.
3. Quits any running HardwareMonitor, production included.
4. Installs the app to `~/Applications/HardwareMonitor Dev.app` and removes the build copy, so only one bundle with ID `local.hardwaremonitor.dev` exists.
5. Launches the app.

Any extra arguments are passed on to the app, for example `./scripts/build-app.sh --log-events`. `BUNDLE_ONLY=1 ./scripts/build-app.sh` builds and signs the production bundle `.build/HardwareMonitor.app` without installing it (the release workflow uses this).

To go back to production:

```sh
pkill -x HardwareMonitorDev; open /Applications/HardwareMonitor.app
```

Always launch the installed app (with the script, or with `open`), not the binary from a terminal.

To run the self-test of the pure logic (it exits before any UI, and a failure gives a non-zero exit status):

```sh
swift run HardwareMonitor --self-test
```

The snapshot and behaviour tests need Xcode (its license accepted): `./scripts/test.sh`; with the coverage gate: `./scripts/coverage.sh`.

To publish a release (owner): `./scripts/release.sh` bumps the version, verifies the build, commits, tags and pushes; the Release workflow builds, signs and publishes the DMG and the zip the updater downloads.

### Event log (diagnostics)

Launch with `--log-events` to append millisecond-timestamped plain-text lines to:

```
~/Library/Logs/HardwareMonitor/events.log        # production
~/Library/Logs/HardwareMonitor Dev/events.log    # HardwareMonitor Dev
```

The file is cleared at each launch and removed when the app starts without the flag. It records the chip, the resolved temperature key counts and whether the SMC and IOReport are available at launch, the duration of every 30th tick, image updates, visibility changes, panel open and close, the IOReport setup, every `ps`/`top` run (duration, exit status, rows), and updater activity. To read it:

```sh
./scripts/build-app.sh --log-events
tail -f ~/Library/Logs/HardwareMonitor\ Dev/events.log
```

## Licence

MIT, see [LICENSE](LICENSE).
