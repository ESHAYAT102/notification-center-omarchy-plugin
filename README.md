# Notification Center

A bar button that opens a scrollable panel listing live and recent notifications
for the Omarchy bar. Right-clicking the bell toggles Do Not Disturb and swaps
the icon to a bell-slash while notifications are silenced.

## Install

```sh
omarchy plugin add https://github.com/ESHAYAT102/notification-center-omarchy-plugin --enable
```

## Usage

- **Left-click** the bell to open or close the notification panel.
- **Right-click** the bell to toggle Do Not Disturb.
- **Escape** closes the panel.
- Optional keybinding for the panel:

```sh
omarchy shell i 'hl.dsp.add("SUPER + A", "Notification Center", "omarchy-shell esh.notification-center toggle")'
```

## Configure

Move the widget on the bar:

```sh
omarchy bar move esh.notification-center --section right
```

## Remove

```sh
omarchy plugin remove esh.notification-center
```

## Notes

- Notifications silenced by Do Not Disturb do not create popups, matching the built-in Omarchy behavior.
- The plugin reads live popups and persisted notification history from the `omarchy.notifications` service; no extra services or privileges are used.

