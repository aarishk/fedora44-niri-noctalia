# Fedora 44 Niri and Noctalia Setup

This file records the desired setup and the changes used to reproduce it.

## Display

- Connector: `DP-2` (`GIGA-BYTE TECHNOLOGY CO., LTD. AORUS FO32U2P`)
- Resolution: `3840x2160`
- Refresh rate: `240 Hz`
- Scale: `1.75` (175%)
- Persistent configuration: `~/.config/niri/config.kdl`
- Use the output name reported by `niri msg outputs`; it can include the monitor's model and serial number.

```kdl
output "<niri-output-name>" {
    mode "3840x2160@240.000"
    scale 1.75
}
```

## Shell Bar

- Noctalia provides the desktop shell.
- Waybar is removed from niri startup, stopped, systemd-disabled, and uninstalled.
- Removed startup entry: `spawn-at-startup "waybar"`

Remove the startup entry from `~/.config/niri/config.kdl`, then run:

```bash
systemctl --user disable --now waybar.service
pkill -x waybar || true
sudo dnf remove waybar
```

## Window Decorations and Shortcuts

- Ask applications to omit client-side decorations with `prefer-no-csd`.
- Close the focused window with `Super+W` or `Super+Q`.
- `Super+W` uses niri's normal `close-window` request; it does not forcibly kill the process.
- Restart existing applications for the decoration preference to take effect.

```kdl
prefer-no-csd

binds {
    Mod+W repeat=false { close-window; }
}
```

## Input

- External mouse acceleration uses libinput's flat profile.
- The touchpad configuration is unchanged.

```kdl
input {
    mouse {
        accel-profile "flat"
    }
}
```

## Theme and Applications

- Noctalia currently uses its built-in Nord palette in dark mode.
- Noctalia uses JetBrains Mono.
- GTK uses `adw-gtk3-dark`, Papirus icons, and SF Pro Rounded for UI text.
- Qt6 uses qt6ct with the Noctalia-generated palette, Papirus icons, and SF Pro Rounded for UI text.
- Fixed-width GTK and Qt fields use SF Mono; Kitty remains monospaced.

## Authorization

- Noctalia is the only desktop PolicyKit authentication agent in the niri session.
- `polkitd` and temporary `polkit-agent-helper-1` processes are required system components, not duplicate desktop agents.

## External Monitor Brightness

- Noctalia DDC support is enabled with `ddcutil` in the active Noctalia profile.
- The AORUS FO32U2P is detected on `DP-2` and advertises DDC brightness control.
- Current DDC VCP brightness reads fail over the active 4K/240 Hz DisplayPort connection, so use the monitor OSD until its DDC/CI connection is reliable.

## Verification

```bash
niri validate
niri msg outputs
noctalia config validate
systemctl --user is-enabled waybar.service
rpm -q waybar
pgrep -a waybar
ddcutil detect --brief
```

Future Fedora, niri, and Noctalia changes should be added to this file.
