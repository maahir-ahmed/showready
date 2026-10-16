# ShowReady 1.3.1

Pre-show checks for a 3-PC esports broadcast: 2 x OMT/NDI 1080p60 in, SRT to France plus YouTube and Twitch out, all 1080p60.

## Download (no GitHub login needed)

**[ShowReady-kit.zip](https://github.com/thomasyuxizeng/showready/releases/latest/download/ShowReady-kit.zip)**: the complete kit, including `bin\ffmpeg.exe` and the upload key.

Unzip it on every PC (right-click the zip > Properties > Unblock first), then follow `README.txt`:

1. `Run-Prep.cmd` on each PC, as administrator (language, drivers, power, startup, network). `Undo-Prep.cmd` reverts it. On Windows Home "Single Language" PCs, prep offers an edition switch so English can be installed. You confirm it by typing HOME. Windows is then **not activated** and the switch **cannot be undone**; run `Run-Prep.cmd` again after the restart.
2. `Run-Observer.cmd` on both observer PCs.
3. `Run-ShowReady.cmd -LanHosts <observer IPs>` on the prod PC.

Results upload automatically to [showready-results](https://github.com/thomasyuxizeng/showready-results).

## What is in this repo

All the scripts, in the same layout as the zip. Two files are left out:

- `bin\ffmpeg.exe` is over GitHub's 100 MB file limit, so it ships only in the release zip.
- `upload.json` holds the upload key, so it ships only in the release zip. That key can write only to the results repo, not to this one.

## Third-party binaries

- `bin\ffmpeg.exe`: FFmpeg n8.1.3-18-g46d899d7a0 (2026-10-15), GPL build from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds) (licence in `bin\FFMPEG-LICENSE.txt`). The source is available at [ffmpeg.org](https://ffmpeg.org/download.html) and [FFmpeg/FFmpeg@46d899d7a0](https://github.com/FFmpeg/FFmpeg/commit/46d899d7a0).
- `bin\iperf3.exe`: iperf3 3.22 (BSD), with `cygwin1.dll` (LGPL).
