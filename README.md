# SmartThings AC

Turn an air conditioner on and off and set its temperature from the Omarchy
bar. The bar shows the room temperature while the unit is running.

Built for a Samsung WindFree, but nothing in it is Samsung-specific: any air
conditioner SmartThings exposes works the same way.

## What it does not do

Mode (cool / dry / wind / auto / heat), fan speed, scheduling, and more than
one unit at a time. All are possible; none are here yet.

There is no local control. Newer Samsung units answer only through Samsung's
cloud — the local protocol older models spoke on port 2878 is gone — so this
plugin talks to SmartThings and needs the internet to do anything.

## Requirements

- Omarchy 4 (Quattro)
- `curl`, `jq`, and `secret-tool` with a running keyring daemon

## Install

```bash
omarchy plugin add https://github.com/artur-hash/omarchy-smartac.git --enable
```

## Setup

Click the icon in the bar. With no token stored, the panel is the setup screen:

1. Open [account.smartthings.com/tokens](https://account.smartthings.com/tokens)
2. Generate a new personal access token
3. Grant only the **Devices** scopes: list, read, execute
4. Paste it into the panel

Then pick your air conditioner from the list.

## About the token

A SmartThings personal access token grants control of **every device in your
account**, not only the one you pick here. Grant only the Devices scopes: this
plugin needs nothing else, and a token limited to those cannot reach your
account settings, your locations, or your other users.

The token is stored in your login keyring through `secret-tool`, never in a
configuration file. It is written to the backend on stdin rather than passed as
an argument, because an argument is visible in `/proc/<pid>/cmdline` to every
process running as you.

To remove it:

```bash
~/.config/omarchy/plugins/arturhash.smartac/bin/smartac token clear
```

Revoke it at [account.smartthings.com/tokens](https://account.smartthings.com/tokens).

## When a setting does not take

Some units silently ignore a command that does not apply to their current
state. The cloud still answers `COMPLETED` — the device simply drops it. The
panel reads the state back a few seconds after every write and says so when
the value did not change, rather than showing a button that quietly springs
back.

Observed on a Samsung AR12BSEAAWKNAZ:

- **WindFree only engages in `cool`.** In `auto` or `heat` the preset is
  accepted and discarded.
- **The setpoint cannot be changed while the unit is off.**
- **Each mode keeps its own setpoint**, so the temperature shown changes on its
  own when the mode does. That is the device remembering, not a misread.

None of these rules are hardcoded. Other hardware has other constraints, and a
list written here would go stale the first time a firmware update moved one.

## Diagnostics

```bash
bin/smartac doctor
bin/smartac doctor --capabilities --device <id>
```

The second prints the raw capability list your device reports, which is the
quickest way to find out why a control is missing.

## Removal

```bash
omarchy plugin remove arturhash.smartac
```

Nothing is left behind but the keyring entry, which `token clear` removes.
There is no systemd unit and no file outside the plugin directory.

## License

MIT.
