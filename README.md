# bright

Extra brightness for the MacBook Pro XDR screen, from your terminal.

MacBook Pro XDR panels keep their top brightness range for HDR content. `bright` makes that range available to everything on screen. It is one Swift file of under 500 lines, and you build it yourself with one command. You don't need an Apple developer account, signing or an App Store download.

```
  bright  ON   ████████████████░░░░  80%
  start at login  OFF
  space on/off   left/right level   l login   q quit
```

> `bright` is a small rewrite of one technique from [BrightIntosh](https://github.com/niklasr22/BrightIntosh) by Niklas Rousset, which did the hard work of figuring it out. If you want a proper Mac app with a menu bar icon, settings, automation and external display support, use BrightIntosh.

## Install

You need a Mac with Apple's Swift compiler (Xcode or the Command Line Tools).

```sh
git clone https://github.com/kuniiii/bright
cd bright
swiftc -O bright.swift -o bright
./bright on
```

To run it from anywhere, link it into a folder on your `PATH`:

```sh
mkdir -p ~/.local/bin
ln -sf "$PWD/bright" ~/.local/bin/bright
```

The compiler signs the build for your own machine, and macOS doesn't quarantine a binary you built locally, so there is no Gatekeeper prompt to get past.

## Use

| Command | What it does |
|---|---|
| `bright` | Opens the small panel: space turns it on or off, left and right change the level, l toggles start at login, q quits |
| `bright on [0-100]` | Turns it on, optionally at a level |
| `bright off` | Turns it off, and the screen goes straight back to normal |
| `bright toggle` | Flips on or off |
| `bright set 0-100` | Changes the level |
| `bright status` | Shows the state, the level, the start-at-login setting and the HDR headroom |
| `bright login [on\|off]` | Shows or changes whether it starts at login |

It keeps running after you close the terminal. It stops when you run `bright off`, restart or log out.

Start at login is off until you turn it on. `bright off` only affects the current session, so if the setting is on, `bright` comes back at the next login. macOS may show a notification when you turn it on, and you can also block it in System Settings under General, Login Items.

## How it works

1. A one-pixel window in the corner of the screen draws a value above 1.0, which is brighter than standard white. This makes macOS switch the panel into its HDR range.
2. `bright` scales the display's gamma table up, so everything on screen uses part of that range.
3. It follows the HDR headroom macOS reports. On a 14-inch M4 Pro at level 100, the boost measured between 1.3x and 1.5x depending on the brightness setting.

When you press the brightness keys, dimming fades straight away over 0.2 seconds. Brightening waits about 1.5 seconds for the panel to settle, then fades the same way.

`bright off` restores the gamma table. macOS also restored it in testing when the process was force-killed.

It runs as a `launchd` job rather than a child of your terminal, which is why closing the terminal doesn't stop it. Start at login adds the same job to `~/Library/LaunchAgents`.

## Compatibility

Tested on one machine: a 14-inch MacBook Pro with M4 Pro on macOS 15.7.

It should work on other Apple silicon MacBook Pros with an XDR screen, but I haven't tried them. The multiplier uses reference values from BrightIntosh for each screen generation.

It only boosts the built-in screen. MacBook Air and other screens without the XDR panel are not supported.

## Good to know

- **Brightness, not gamut.** Colors look punchier, but the screen can't show any new ones.
- **Battery and heat.** Running the panel brighter uses more power and makes more heat. Run `bright off` when you don't need it.
- **Bright highlights.** Parts of the image that are already very bright can lose some detail.
- **Brightening lags a little.** The boost catches up about 1.5 to 2 seconds after you raise the brightness.
- **One gamma app at a time.** Don't run `bright` alongside BrightIntosh or other apps that change gamma. They will overwrite each other.
- **Not tested yet.** I haven't checked how it behaves with screenshots, screen recordings or HDR video.
- **No automatic retry.** If the boost doesn't appear, run `bright off`, then `bright on`. BrightIntosh handles these failures for you. `bright` doesn't.

## Uninstall

```sh
bright login off
bright off
rm ~/.local/bin/bright
rm -rf ~/Library/Application\ Support/bright
```

Then delete the cloned folder.

## License

GPL-3.0, the same as BrightIntosh, which this is based on. See [LICENSE](LICENSE).
