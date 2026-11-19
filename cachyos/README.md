# Micachy on CachyOS / KDE Plasma

This branch runs Micachy outside Omarchy. Step 1 (this folder) gets the
lighting and cooler display working with the CLI only; a Plasma widget and
KDE theme colours come later.

## 1. udev rule (once, needs root)

Same two lines as the main README — the board's Aura controller and the
cooler display are root-only hidraw nodes until this lands:

```bash
printf '%s\n' \
  'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="5131", ATTRS{idProduct}=="2007", TAG+="uaccess", RUN{builtin}+="uaccess", GROUP="input", MODE="0660"' \
  'SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0b05", ATTRS{idProduct}=="19af", TAG+="uaccess", RUN{builtin}+="uaccess", GROUP="input", MODE="0660"' \
  | sudo tee /etc/udev/rules.d/99-micachy.rules >/dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --action=add --subsystem-match=hidraw
```

### Optional: join the `input` group

The `uaccess` tag grants the nodes to whoever holds the active login session,
and logind applies that grant a few seconds *after* `systemd --user` has
already started the daemons. So at every login both services fail once or
twice with "permission denied" and only stick when `Restart=on-failure`
retries them — about 20 seconds of dark lights and two misleading "install
the udev rule" lines in the journal.

The rule also sets `GROUP="input"`, which is in force from the moment the
node appears, so group membership closes the race:

```bash
sudo usermod -aG input "$USER"   # then log out and back in
```

The cost: `input` also owns `/dev/input/event*`, so every program you run can
then read raw keystrokes. If you would rather not grant that, skip this step —
the retry gets there on its own.

## 2. Configure zones

```bash
/usr/bin/python3 bin/micachy-setup
```

## 3. Daemons as user services

```bash
cachyos/install-units               # lightd + displayd, enabled at login
cachyos/install-units --no-display  # lighting only
cachyos/install-units --uninstall
```

Logs: `journalctl --user -u micachy-lightd -f`.

## 4. Control

```bash
/usr/bin/python3 bin/micachy-ctl status
/usr/bin/python3 bin/micachy-ctl effect rainbow
```

Bind these to KDE global shortcuts (System Settings → Keyboard → Shortcuts →
Add New → Command) for keyboard control.
