# Mimarchy on CachyOS / KDE Plasma

This branch runs Mimarchy outside Omarchy. Step 1 (this folder) gets the
lighting and cooler display working with the CLI only; a Plasma widget and
KDE theme colours come later.

## 1. udev rule (once, needs root)

Same two lines as the main README — the board's Aura controller and the
cooler display are root-only hidraw nodes until this lands:

```bash
printf '%s\n' \
  'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="5131", ATTRS{idProduct}=="2007", TAG+="uaccess", RUN{builtin}+="uaccess", GROUP="input", MODE="0660"' \
  'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="19af", TAG+="uaccess", RUN{builtin}+="uaccess", GROUP="input", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/99-mimarchy.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=hidraw
```

## 2. Configure zones

```bash
/usr/bin/python3 bin/mimarchy-setup
```

## 3. Daemons as user services

```bash
cachyos/install-units               # lightd + displayd, enabled at login
cachyos/install-units --no-display  # lighting only
cachyos/install-units --uninstall
```

Logs: `journalctl --user -u mimarchy-lightd -f`.

## 4. Control

```bash
/usr/bin/python3 bin/mimarchy-ctl status
/usr/bin/python3 bin/mimarchy-ctl effect rainbow
```

Bind these to KDE global shortcuts (System Settings → Keyboard → Shortcuts →
Add New → Command) for keyboard control.
