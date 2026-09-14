# YouTube Background

Play a YouTube video (or anything mpv and yt-dlp can open) as a live desktop
background on Omarchy. The video draws above the wallpaper and below every
window, clicks pass straight through it, and the bar gets a YouTube glyph with a
popout for picking the video, pausing, muting and setting quality.

Playback is done by [mpvpaper](https://github.com/GhostNaN/mpvpaper), a
layer-shell wrapper around mpv. The plugin owns that process, talks to mpv over
its JSON IPC socket, and keeps its settings on the plugin's entry in
`~/.config/omarchy/shell.json`.

## Requirements

- Omarchy 4 with shell plugin support
- `mpvpaper` (AUR) and `yt-dlp`

```bash
omarchy pkg aur add mpvpaper
omarchy pkg add yt-dlp
```

## Install

```bash
omarchy plugin add https://github.com/RonHolt/omarchy-youtube-background.git
omarchy plugin enable ron.youtube-background --section right
```

Or by hand:

```bash
git clone https://github.com/RonHolt/omarchy-youtube-background.git ~/.config/omarchy/plugins/ron.youtube-background
omarchy-shell shell rescanPlugins
omarchy plugin enable ron.youtube-background --section right
```

Plugins run unsandboxed inside the shell process, so read the code before
enabling it.

## Use

Click the YouTube glyph in the bar. Paste a URL (or a bare 11-character video
id) and press Enter or the play button. The chevron next to the field lists
the last ten videos that played, by title; pick one to play it again.

| In the bar | Does |
| --- | --- |
| Left click | Open the panel |
| Middle click | Pause / resume |
| Right click | Start / stop the saved video |

Inside the panel, the arrow keys walk a cursor over every row, so all of it
works without a mouse:

| Key | Does |
| --- | --- |
| `Up` / `Down` | Move the cursor between rows |
| `Left` / `Right` | Act on the row: pick a transport button, nudge a slider, step a dropdown |
| `Enter` / `Space` | Activate the row: press the button, edit the field, open the dropdown, flip the toggle. With no cursor showing: play / pause |
| `p` | Play / pause / resume |
| `s` | Stop |
| `m` | Mute / unmute |
| `u` or `/` | Edit the URL |
| `r` | Open the recently played list |
| `h` / `l` | Skip back / forward 5 seconds |
| `j` / `k` | Skip back / forward 60 seconds |
| `Tab` / `Shift+Tab` | Next / previous bar panel |
| `Esc` | Leave a field or dropdown, otherwise close the panel |

Hovering with the mouse moves the same cursor. Skipping and the position
slider are hidden for live streams, which mpv reports as not seekable.

The video starts muted at 50 percent volume. Whatever was playing when you log
out resumes at the next login.

## Command line

Every control is also an IPC verb, handy for keybindings and the Omarchy menu.
Each prints the resulting value.

```bash
omarchy-shell youtube-background play "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
omarchy-shell youtube-background play ""            # replay the saved URL
omarchy-shell youtube-background stop
omarchy-shell youtube-background toggle             # start or stop
omarchy-shell youtube-background pause toggle       # get|true|false|toggle
omarchy-shell youtube-background mute toggle        # get|true|false|toggle
omarchy-shell youtube-background volume 30          # get|0-100
omarchy-shell youtube-background seek +10           # get|+<secs>|-<secs>|<secs>  (signed = relative)
omarchy-shell youtube-background quality 1440       # get|best|2160|1440|1080|720|480
omarchy-shell youtube-background codec h264         # get|h264|vp9|any
omarchy-shell youtube-background url get
omarchy-shell youtube-background cookies brave+gnomekeyring:Default   # get|<browser spec>|<path>|"" to clear
omarchy-shell youtube-background history get       # get|clear; JSON list of {url, title}, newest first
omarchy-shell youtube-background status             # JSON incl. position, duration, seekable
```

Changing the URL while playing swaps the file inside the running mpv, so there
is no flash of wallpaper. Changing quality or codec restarts mpvpaper.

Example keybinding in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + SHIFT + Y", "Toggle video background", "omarchy-shell youtube-background toggle")
```

Example rows for `~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
"style.video-bg": {"icon": "󰗃", "label": "Video Background"},
"style.video-bg.toggle": {"icon": "󰐊", "label": "Start / Stop", "action": "omarchy-shell youtube-background toggle"},
"style.video-bg.pause": {"icon": "󰏤", "label": "Pause / Resume", "action": "omarchy-shell youtube-background pause toggle"},
"style.video-bg.mute": {"icon": "󰝟", "label": "Mute", "checked": "[[ \"$(omarchy-shell youtube-background mute get)\" == \"true\" ]]", "action": "omarchy-shell youtube-background mute toggle"}
```

## Settings

All on the plugin's entry in `shell.json`, editable by hand. The panel and
IPC verbs write the common ones.

| Key | Default | Meaning |
| --- | --- | --- |
| `url` | | Video URL |
| `playing` | `false` | Resume at login |
| `muted` | `true` | |
| `volume` | `50` | 0 to 100 |
| `quality` | `"1080"` | Max height, or `"best"` |
| `codec` | `"h264"` | Preferred codec: `h264`, `vp9`, `any` |
| `fill` | `true` | Crop to fill (`panscan=1.0`) instead of letterboxing |
| `outputs` | `"ALL"` | Monitor name, or `ALL` |
| `layer` | `"bottom"` | Layer-shell layer. `background` puts it under the wallpaper renderer, so leave it |
| `hwdec` | `"auto-safe"` | mpv `hwdec` value |
| `extraOptions` | | Extra mpv options, space separated, `key=value` form |
| `cookiesFromBrowser` | | yt-dlp `--cookies-from-browser` spec, e.g. `brave+gnomekeyring:Default`, see below |
| `cookiesFile` | | Netscape `cookies.txt` passed to yt-dlp, see below |
| `history` | `[]` | Last ten videos played, `{url, title}` newest first; written by the plugin |

## When a video will not load

The panel shows yt-dlp's own reason instead of spinning. The common one:

> Sign in to confirm you're not a bot

YouTube serves that to anonymous clients for some videos (long mixes and
livestream re-uploads are frequent targets) even when other videos work fine
from the same machine. yt-dlp needs a signed-in YouTube session for those.
There is no OAuth or device-code login any more (Google shut yt-dlp's down),
so the session comes from a browser, in one of two ways.

### Use the browser's live login (recommended)

yt-dlp can read a browser's cookie store directly, so as long as you are
signed into YouTube in that browser the wallpaper is too, with nothing to
export or refresh. Put a `--cookies-from-browser` spec in the panel's
"Cookies" field or run:

```bash
omarchy-shell youtube-background cookies brave+gnomekeyring:Default
```

The spec is `browser[+keyring][:profile]`. On Omarchy the pieces are:

- browser: `brave`, `chromium`, `chrome`, `firefox`, `vivaldi`, `edge`, ...
- keyring: Chromium-family browsers encrypt cookies with a key kept in the
  desktop keyring. Omarchy runs GNOME Keyring, so use `+gnomekeyring`, which
  needs the `python-secretstorage` package (`omarchy pkg add python-secretstorage`).
  `+basictext` is for browsers running without any keyring; `+kwallet` will
  pop a KWallet password dialog you do not want. Firefox needs no keyring part.
- profile: the directory name under the browser's config dir (`Default`,
  `Profile 2`), or a full path. Pick the profile that is signed into YouTube.

Check a spec before trusting it to the wallpaper:

```bash
yt-dlp --cookies-from-browser brave+gnomekeyring:Default --skip-download --print title <url>
```

The browser can stay open; yt-dlp copies the cookie DB before reading it.

### Or a cookies.txt file

Export youtube.com cookies in Netscape format with a "Get cookies.txt"
extension, save the file somewhere without spaces in the path, and set that
path in the same field (anything starting with `/` or `~` is treated as a
file). Cookies in a file go stale when YouTube rotates the session; the
browser spec does not.

Either way the plugin now has a live login to your Google account, so use a
throwaway account if you would rather not hand your main session to a
background process. See the
[yt-dlp wiki](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies)
for the details.

## Performance

yt-dlp ranks AV1 first, and most GPUs before 2020 cannot decode AV1 in
hardware. That is why `codec` defaults to H.264, which gets VA-API/NVDEC on
everything. Measured on an i7-8565U (UHD 620) with the Big Buck Bunny 720p60
stream:

| codec | decode | mpvpaper CPU |
| --- | --- | --- |
| AV1 | software | 45 to 50 percent of one core |
| H.264 | vaapi | about 7 percent |

Lower `quality` to spend less.

## How it works

- `Service.qml` first resolves every network URL with `yt-dlp --print`
  (title, picked codec, height, fps). Only a URL that resolves is handed to
  mpvpaper; a failure is shown in the panel with yt-dlp's message. The same
  cookie arguments go to mpv as `ytdl-raw-options`, so its own yt-dlp call
  at load time (and on every retry) sees the same session.
- It then spawns `mpvpaper -l bottom -p -o "<mpv options>" ALL <url>` and
  connects to mpv's `input-ipc-server` socket in `$XDG_RUNTIME_DIR` for
  pause/mute/volume/title and error events.
- Stream URLs from YouTube expire after a few hours. On a playback error the
  service re-resolves through yt-dlp with backoff (5s, 10s, ... up to 2 min,
  six attempts) and reports the reason if it keeps failing.
- Stopping sends `quit` over IPC, then SIGTERM, then SIGKILL. mpvpaper 1.9
  deadlocks in its exit path (and ignores SIGTERM) when its file never loaded,
  which is the state a bad URL used to leave it in. A watchdog also kills a
  mpvpaper whose mpv never opens its socket within 30 seconds.
- On (re)start it kills any orphaned mpvpaper matched by that socket path, so a
  crashed shell never leaves an uncontrolled video behind.
- `BarWidget.qml` + `Panel.qml` follow the standard Omarchy bar-widget pattern
  and reach the service through `bar.shell.serviceFor(<own id>)`.

## Limitations

- The lock screen shows the wallpaper, not the video.
- Omarchy's background switcher and theme changes leave the video alone; stop
  it to see your wallpaper again.
- Editing `Service.qml` needs `omarchy restart shell`; the shell's hot reload
  re-instantiates a service from cached code. Widget and panel edits hot-reload
  when the plugin lives directly under `~/.config/omarchy/plugins/`, but not
  when that entry is a symlink (the watcher does not follow it), so a symlinked
  checkout needs `omarchy restart shell` for every edit.

## Uninstall

```bash
omarchy-shell youtube-background stop
omarchy plugin remove ron.youtube-background
```

The plugin writes only its own entry in `~/.config/omarchy/shell.json` and
the mpv socket in `$XDG_RUNTIME_DIR`; removing it leaves nothing else behind.
Packages you installed for it (`mpvpaper`, `yt-dlp`) stay until you remove
them.

## Development

Clone the repo anywhere and symlink it into the plugin directory. Through a
symlink nothing hot-reloads (see Limitations), so restart the shell after
each edit:

```bash
git clone https://github.com/RonHolt/omarchy-youtube-background.git ~/omarchy-youtube-background
ln -s ~/omarchy-youtube-background ~/.config/omarchy/plugins/ron.youtube-background
omarchy plugin validate ~/omarchy-youtube-background
omarchy restart shell                                  # after any edit through a symlink
omarchy-shell youtube-background status                # JSON incl. ipc and probing flags
qs log -p /usr/share/omarchy/shell --tail 100 | grep youtube-background
```

## License

MIT
