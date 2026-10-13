# End-to-end Addon Forge: NixOS realm + Windows/Linux WoW

Experimental path. Cloud NixOS and Windows input passed automated CI checks,
but no actual Hetzner NixOS boot + live WoW login has been verified yet.

## 1. Deploy a disposable x86 Hetzner instance

Follow [cloud/README.md](../cloud/README.md) for server provisioning, the
**destructive**, server-ID-approved nixos-anywhere installation from Linux/WSL2,
and initial AzerothCore Docker diagnostics. Server charges accrue until deletion,
even when powered off. Never run an installer on a server with valuable data.

The deployed realm publishes **only** TCP 3724/8085 on the server's loopback
and exposes **only** SSH inbound through Hetzner's allowlisted firewall.

## 2. Determine realm address (once)

AzerothCore includes a `realmlist` SQL table in the auth database. After the
first database import, its `address` should be `127.0.0.1` for an SSH
port-forwarded client, because WoW contacts the realm address returned at login.

Use a **private remote SSH session** and inspect the database:

```bash
ssh root@YOUR_HETZNER_IP
forge-realm status
docker exec -it addon-forge-ac-database-1 mysql -uroot -p acore_auth \
  -e 'SELECT id,name,address,localAddress,localSubnetMask,port FROM realmlist;'
```

If the address is not loopback, change it **only after confirming the correct
database/container**. MySQL root password is generated on the server at
`/var/lib/addon-forge-realm/.env` and should not be pasted into a terminal
history/chat. AzerothCore may require a realm restart to reload the address.

Do not publicly expose 3724/8085 as a workaround.

## 3. Connect the local game from Windows or Linux

Install the Forge CLI **natively** on the machine running WoW (native Windows
Python for Windows, Nix/Linux Python for Linux). Use a local authorized,
functioning WoW 3.3.5a installation and enable ForgeTestBridge.

On Windows PowerShell:

```powershell
py -3.11 -m pip install -e ".[windows]"
forge --config forge.toml realmlist --locale enUS
forge --config forge.toml tunnel YOUR_HETZNER_IP
```

On Linux:

```bash
python3 -m pip install -e .
forge --config forge.toml realmlist --locale enUS
forge --config forge.toml tunnel YOUR_HETZNER_IP
```

Both `forge tunnel` commands are **foreground**, binding only local
127.0.0.1 ports 3724 and 8085 and forwarding through SSH. Root SSH must be
key-authenticated and the server SSH host key must already be trusted in
`known_hosts`; do not disable host key checks. If your SSH identity differs,
provide `--identity /path/to/private-key`, and use `--user` if needed.
Opening the tunnel requires SSH inbound from that computer's public IP to be
allowed by the existing Hetzner firewall.

The local `realmlist` command backs up your original
`Data/<locale>/realmlist.wtf` before setting its address to 127.0.0.1;
revert by restoring `realmlist.wtf.forge-backup`. It does **not** modify server
database addresses.

Keep the tunnel running, then in a *second terminal*:

```bash
forge --config forge.toml deploy wow/ForgeTestBridge
forge --config forge.toml deploy examples/ForgeExample
forge --config forge.toml client start
# Log in manually, enable addons and enter the world, then:
forge --config forge.toml test --suite smoke
```

Run `forge client screenshot .forge-runs/window.png` for visual verification.
Use windowed WoW; Windows needs an unlocked interactive desktop.

## Important limitations

- No auto login, WoW assets or game account provisioning. Bring a legal local
  WoW installation and personal test account.
- Only the realm runs on cloud; GPU-backed game rendering/tests are local.
- First run may fail due to mismatched AzerothCore image tags, missing extracted
  map data, database initialization or network settings. Check logs before retrying.
- The client might not support realm selection through localhost if its
  realmlist database `address` points elsewhere. Database inspection is required.
- Initial login through the tunnel has not been tested against a live server.
