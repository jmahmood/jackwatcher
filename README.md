# Jackwatcher

A "plug and forget" Audio Player for ROCKNIX devices.

Currently this only supports the RG35XX Plus.

## How does it work?

"Jack Watcher" is a background process that blocks and waits for a headphone insertion event.  If it finds one, it immediately triggers the musicctl.sh script, which then plays audio files in a pre-determined directory.

It currently runs as root, as it assumes access to `/dev/input/event`.  As such it is NOT suitable for use on a device with sensitive information.  

The event reads are blocking, so idle CPU is effectively 0%.

## Prereqs

* A ROCKNIX build on an **RG35XX Plus** (root SSH access).
* On your dev machine: Rust toolchain + optionally `cross`.
* On the device: at least **one** of `mpv`, `mplayer`, `mpg123`, or `ffplay` available in `$PATH`.

  ```sh
  which mpv mplayer mpg123 ffplay | cat
  ```
* Audio files under `/storage/audio` (default) or whatever you pass to `deploy.sh --music-dir`.

## Quickstart

There is a deploy.sh file that ChatGPT kindly prepared for me.  As long as you have your device running over wifi, and can SSH into it, you should be able to use the script as laid out below.  

```
# From your dev linux machine

$ ./deploy.sh --host root@10.0.0.159

# Optional flags:
./deploy.sh --host root@DEVICE_IP --music-dir /storage/podcasts     # change source dir
./deploy.sh --host root@DEVICE_IP --prefix /storage                  # change install prefix
./deploy.sh --host root@DEVICE_IP --dry-run                          # show what would happen
./deploy.sh --host root@DEVICE_IP --skip-build                       # reuse existing local build
```

The wrapper `/storage/bin/jack-watcher-run` pins JW_CMD=/storage/bin/musicctl and runs --watch --exec, so you don’t need to pass paths.


This installs to `/storage/bin` by default:

* `/storage/bin/jack-watcher` (the daemon)
* `/storage/bin/musicctl` (the player controller)
* `/storage/bin/jack-watcher-run` (wrapper that pins config and runs `--watch --exec`)

Run it (no systemd required):

```bash
ssh root@DEVICE_IP /storage/bin/jack-watcher-run
# plug/unplug 3.5mm; it should start/stop playback
```

Optional service (if your image supports it):

```bash
./deploy.sh --host root@DEVICE_IP --service
```

If you want to install manually, you can copy the files over to the memory card, but I'm too lazy to figure that out, sorry.


## Verify it’s wired correctly

List devices and current state:

```bash
/storage/bin/jack-watcher --list
# expect something like:
# /dev/input/event1 H616 Audio Codec Headphone Jack   hp_switch=true initial=0
```

Foreground watch with logs:

```bash
/storage/bin/jack-watcher --watch --exec
# or just use the wrapper:
/storage/bin/jack-watcher-run
```

## Configuration knobs

* **Music directory:** set with deploy flag:

  ```bash
  ./deploy.sh --host root@DEVICE_IP --music-dir /storage/podcasts
  ```

  (Installer rewrites `musicctl`’s `DIR=…` line.)
* **Controller path:** the watcher honors `JW_CMD` env or `--cmd`, but the wrapper already sets:

  ```sh
  export JW_CMD="/storage/bin/musicctl"
  ```
* **Player selection/order:** `musicctl` auto-selects the first present in `mpv → mplayer → mpg123 → ffplay`. Edit the script if you want a fixed one.
* **Front-ends to kill on start:** tweak `KILL_THESE` in `musicctl` (e.g., `retroarch emulationstation gmu.bin`).
* **Mixer routing:** `musicctl` nudges `Headphone`/`Speaker` via `amixer`. If your mixer names differ, edit the two amixer lines in musicctl to match your controls (e.g., Headphone/Speaker → your codec’s names).

## Uninstall

```bash
./deploy.sh --host root@DEVICE_IP --uninstall
```

This also removes the wrapper and systemd unit (if present). To stop a service without uninstalling:

```bash
ssh root@DEVICE_IP 'systemctl stop jack-watcher && systemctl disable jack-watcher'
```

## Known limitations / roadmap

* Currently reacts only to **headphone jack insert/remove** (no hotkeys for skip/pause yet).
* Resume position/artwork not implemented (see TODO).
* Requires at least one CLI player present on the device.


## Troubleshooting

* **“Playlist has 0 items” / no sound:** confirm the music directory has files:

  ```bash
  find /storage/audio -maxdepth 1 -type f | head
  ```

* **No player found:** install or ensure at least one of `mpv/mplayer/mpg123/ffplay` exists, or edit `musicctl` to point at a known binary on your image.

* **No events when plugging 3.5mm:** check device list:

  ```bash
  /storage/bin/jack-watcher --list
  ```

  If nothing shows `hp_switch=true`, your build may not expose `SW_HEADPHONE_INSERT`.

* **It runs but keeps BGM playing:** either disable EmulationStation background music, or keep `KILL_THESE` including `emulationstation` so `musicctl` takes over.



# Never Before Asked Questions

## License

Licensed under GPL3.  May consider dual licensing if it helps package the software if anyone ever wants to do so.

## “Can I run it from SD without systemd?”

Yes: add `/storage/bin/jack-watcher-run` to your firmware’s autostart (or just background it with `nohup … &`).

## “Can I change install dir?”

Use `--prefix /somewhere`; the wrapper makes the binary path-agnostic.

## “What formats are supported?”

Whatever your chosen player supports; `musicctl` scans `mp3/m4a/ogg/opus/flac` by default (adjust the `find` line if needed).

## "Why use this?""

I find it annoying to have to pull out my phone, select an app, select a playlist, fight with the internet, and play music or a podcast before I start my workout.

I want an appliance that I can plug into my speaker and not deal with
	- Bluetooth 
	- Wifi

I just want to plug and play with a device I already have.  The RG35XX Plus has a 3.5 mm plug, and when using evdev, we can detect if something is plugged into the device, be it a speaker system or a headset.

## Why not use the GMU music player?

GMU is included with Rocknix for the RG35XX Plus, but the controls don't work on the RG35XX Plus. Moreover, I can't seem to get it to load any playlist I set, and I can't quit the app once it starts.  Seems like a bad idea until that has been resolved.

## Why not use the /storage/roms/music directory?

I assume users will want to have a different directory for auto-played audio.  Maybe you have an audio book you want to play, or a podcast queue that you do not want as BGM.  You can link the directories if you want to keep them the same.

## What if I want to select my music?

Use something else.  This is meant to be a "plug and forget" style system.

## Why not bluetooth?

Maybe someday, but I doubt it.  The idea is to minimize annoyance, not deal with wifi and bluetooth issues.