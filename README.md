# Omapager + Notification Center

[Omapager](https://github.com/njpatel/omapager)'s notification daemon and exact
card renderer, with a bell that opens a scrollable notification center.
Source-grouped stacks, hover expansion, rich text, resolved icons, actions,
inline phone replies, and snoozing come from omapager.

## Install

```sh
omarchy plugin add https://github.com/ESHAYAT102/notification-center-omarchy-plugin --enable
```

Then run the install script to set up the daemon:

```sh
cd ~/.config/omarchy/plugins/esh.notification-center
bash bin/install
```

This disables `omarchy.notifications`, adds `esh.notification-center` to
`plugins` and the bar layout, and restarts the shell. Only one daemon can
own the notification bus.

To revert to Omarchy's default daemon:

```sh
bash bin/uninstall
```

## Usage

- Left-click the bell to open or close the center; Escape closes it.
- Right-click the bell toggles Do Not Disturb.
- Hover a popup stack to expand it; hover a card for its actions.
- The center shows live and recent notifications, newest first, including muted
  notifications. Opening it pauses popup expiry and never replays history as popups.
- Dismiss a center card to remove it from history; Clear all clears the center,
  pending notifications, and popups. Popup dismissal alone retains history.
- Sender actions remain available in the center after popup expiry and during
  Do Not Disturb, until the sender closes them or the shell restarts. Clicking
  invokes the app’s original action (including browser tab/conversation navigation).
  Restored notifications retain detected copy/link actions and source navigation.
- Omapager's quiet rules apply: critical notifications and, by default,
  verification codes can bypass DND. Set `codesBypassQuiet` to `false` to block codes.

History is bounded to 200 entries / 7 days in `~/.local/state/omarchy/omapager`.
This shares omapager's existing store, so switching preserves its history.
Stock Omarchy notification history from older versions is not imported.

## Keybindings

```sh
omarchy shell i 'hl.dsp.add("SUPER + A", "Notification Center", "omarchy-shell esh.notification-center toggle")'
omarchy shell i 'hl.dsp.add("SUPER + comma", "Clear notifications", "omarchy-shell esh.notification-center clear")'
```

Omapager's `omapager` and stock `notifications` IPC targets remain available.
Inline widget settings support `stacking`, `actionsAlign`, `hideSettingsAction`,
`smartRaise`, `snoozeDurations`, `wakeHour`, and `codesBypassQuiet` as described in
[omapager's settings](https://github.com/njpatel/omapager#settings).

## Remove

```sh
bash bin/uninstall
omarchy plugin remove esh.notification-center
```

Stored history is retained.

See THIRD_PARTY.md and LICENSE.omapager for upstream attribution.

## Check

Run `python test_center.py` in an Omarchy Wayland session. It uses a private
D-Bus session and temporary storage, leaving your notification history untouched.
