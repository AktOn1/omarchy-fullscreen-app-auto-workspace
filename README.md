# Fullscreen App Auto Workspace

Fullscreen games get their own special workspace, like a scratchpad. A game that runs fullscreen or borderless (a window covering its whole monitor) moves there by itself and stays fullscreen. A keybind hides the layer and brings it back. Windowed games and all other apps are left alone.

## Install

```bash
omarchy plugin add https://github.com/AktOn1/omarchy-fullscreen-app-auto-workspace.git --enable
```

Plugins are added disabled by default; `--enable` turns it on right away. Review the code first if you like: it is two small files (`FullscreenAppAutoWorkspace.qml`, `gamelayer.lua`).

## Requirements

- Omarchy 4.x with the shell plugin system (tested on Omarchy 4.0.4, Hyprland 0.56 with Lua config).
- `hyprctl` with `eval` support, as shipped with current Omarchy. No other packages, no network.

## First run

There is no bar item and no window. Start a Wine/Proton/Steam game fullscreen or borderless: it jumps to the `fullscreen` special workspace and stays fullscreen. Press the keybind below to hide it and get your normal workspace back, press it again to return to the game. The keybind does nothing while no game is on the layer.

## Usage

Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + D", "Toggle fullscreen app workspace", "omarchy-shell fullscreen-app-auto-workspace toggle")
```

| Command | Effect |
|---|---|
| `omarchy-shell fullscreen-app-auto-workspace toggle` | Hide the layer, or show it when a game is on it |
| `omarchy-shell fullscreen-app-auto-workspace reload` | Re-read the settings file |

What counts as a game: Wine/Proton `*.exe`, `steam_app_*`, `gamescope`, and windows that declare content type `game`. Browser videos and players are left alone.

## Configuration

Optional file `~/.config/fullscreen-app-auto-workspace/config.json`, picked up automatically when saved. Without it the defaults apply.

```json
{
  "extraClasses": ["^my-game$"],
  "neverFullscreen": ["^my-launcher\\.exe$"],
  "sweepIntervalMs": 1500
}
```

| Key | Default | Meaning |
|---|---|---|
| `extraClasses` | `[]` | Extra window class patterns (regex) that count as games |
| `neverFullscreen` | `[]` | Games that drop their fullscreen at startup. Hyprland decides their fullscreen instead (toggle it yourself) |
| `sweepIntervalMs` | `1500` | How often the safety sweep runs (500 to 10000). Borderless games often size themselves only after opening and nothing fires for a resize, so a slow sweep reacts later but costs less |

## Permissions and behavior

This plugin runs Lua inside Hyprland (`hyprctl eval` of the bundled `gamelayer.lua`, a plain readable file with no network access, no `os.execute`, no `io.popen`). It:

- adds window rules: tag `game` on matching windows, and `suppress_event activatefocus` on tagged windows so Wine games do not pull focus back while the layer is hidden;
- moves game windows to `special:fullscreen` and sets them fullscreen, and moves non-game windows that end up there back to the normal workspace;
- briefly sets `misc.focus_on_activate` to false (2 s) while hiding the layer, then restores your original value (also when the plugin is disabled in that moment);
- listens to window open, fullscreen and active events, plus a periodic sweep timer (`sweepIntervalMs`).

It never edits your Hyprland config files, runs no subprocess other than `hyprctl`, writes no files, makes no network calls and sends no telemetry. Everything it registers is removed again when the plugin is disabled or removed, and it is re-applied when Hyprland reloads its config. It only reads `config.json`, which you create yourself.

## Update

```bash
omarchy plugin update io.github.akton1.fullscreen-app-auto-workspace
```

## Remove

```bash
omarchy plugin remove io.github.akton1.fullscreen-app-auto-workspace
```

Then delete your keybind from `bindings.lua`, and the settings folder if you created one: `rm -rf ~/.config/fullscreen-app-auto-workspace`. The plugin itself leaves nothing else behind.

## Troubleshooting

- A game does not move: check its window class with `hyprctl clients | grep class` and add a matching pattern to `extraClasses`.
- Nothing happens at all: run `journalctl --user -b | grep fullscreen-app-auto-workspace`. The plugin logs a warning when `hyprctl eval` fails (no `hyprctl`, or a Hyprland without Lua config support).
- Bugs and ideas: open an issue at https://github.com/AktOn1/omarchy-fullscreen-app-auto-workspace/issues with your `omarchy version` and the window class of the game.

## License

MIT
