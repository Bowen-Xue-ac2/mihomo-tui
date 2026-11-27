# X · Mihomo terminal

My Windows terminal client for Mihomo, based on [wzk0/mihomo-tui](https://github.com/wzk0/mihomo-tui) v1.4. I use PowerShell for node and mode changes and open the terminal UI for latency tests and logs.

## Daily commands

```powershell
vpn_x                              # Open the X console and start the core if needed
vpn_x status --json                 # Core state, mode, selected node, and delayMs
vpn_x start
vpn_x stop
vpn_x restart
vpn_x nodes GLOBAL                  # Node numbers, last latency, and current selection (*)
vpn_x use GLOBAL 3                  # Select node 3 in the group
vpn_x mode                          # Show the live routing mode
vpn_x mode rule                     # rule, global, or direct
vpn_x system-proxy status
vpn_x system-proxy on
vpn_x system-proxy off
vpn_x tun status
vpn_x tun on
vpn_x tun off
```

`vpn_x` is my local launcher. The compiled executable supports the same subcommands. Put `--data`, `--home`, and `--bin` before subcommands when using the executable. It reads the controller settings from the active `config.yaml`. Run `vpn_x --help` for profile, backup, and core-update options.

### Node selection and routing

`vpn_x nodes <group>` numbers entries from 1 in the group's current order. The latency column shows the last result recorded by Mihomo. Entries without a result show `Untested`, and failed measurements can show `Timeout`. Run `vpn_x nodes <group>` again after refreshing or changing profiles, then pass the new number to `vpn_x use <group> <number>`.

In Global mode, Overview shows the final selection reached through `GLOBAL`. In Direct mode, it shows `DIRECT`. In Rule mode, **MATCH fallback** shows the default route. Use Logs to see the rule and outbound chosen for an individual connection.

`vpn_x status` uses the same route display and shows the node's last recorded delay. In JSON, `delayMs` is `null` when the delay is unavailable and `0` for a recorded timeout.

### Windows system proxy and TUN

The system proxy and TUN have independent controls. Release each one in the existing client before enabling it with `vpn_x`. The Windows TUN adapter is named `vpn_x`.

To enable TUN, run `vpn_x start` in an Administrator terminal, then run `vpn_x tun on`. If the core is already running without elevation, use `vpn_x restart` in that Administrator terminal before retrying. TUN and routing-mode changes apply to the running core. Run `vpn_x tun on` again after restarting the core.

## Keys

| Key | Action |
| --- | --- |
| `1` / `2` / `3` / `4` / `5` | Overview / Profiles / Proxies / Logs / Settings |
| `Tab` / `←→` | Change focus or switch between groups and nodes |
| `Enter` | Select a node or run an action |
| `t` / `T` | Test one node or the entire group |
| `q` | Close the interface and keep the core running |

## Build on Windows x64

Use Dart SDK 3.13.7 and provide the Mihomo executable and your profile separately.

```powershell
dart pub get --enforce-lockfile
New-Item -ItemType Directory -Force build | Out-Null
dart compile exe bin/mihomo_tui.dart -o build/vpn_x.exe
.\build\vpn_x.exe --help
```

This build includes a Windows signal compatibility fix. For upstream profile management and backup instructions, see [the v1.4 documentation](https://github.com/wzk0/mihomo-tui/tree/v1.4).
