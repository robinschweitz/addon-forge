#!/usr/bin/env python3
"""Opt-in Hetzner Cloud bootstrap; no server is created without --approve-cost."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tomllib

def configuration(path):
    with Path(path).open("rb") as f:
        data = tomllib.load(f)
    server = data.get("server", {})
    # Hetzner SSH key *names* may contain '@' (e.g. robin@DESKTOP-KRLA5G1).
    # Restrict infrastructure identifiers, but validate the SSH key separately.
    identifiers = ("name", "type", "location", "image")
    if any(not isinstance(server.get(k), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{1,63}", server[k]) or server[k].startswith("YOUR_") for k in identifiers):
        raise ValueError("Set valid [server] name, type, location and image")
    ssh_key = server.get("ssh_key")
    if (not isinstance(ssh_key, str) or not 1 <= len(ssh_key) <= 255
            or not ssh_key.strip() or ssh_key.startswith(("YOUR_", "-"))
            or any(ord(ch) < 32 or ord(ch) == 127 for ch in ssh_key)):
        raise ValueError("Set [server] ssh_key to the SSH key NAME from 'hcloud ssh-key list'")
    ip = ipaddress.ip_network(data["network"]["ssh_source"], strict=True)
    if ip.num_addresses != 1 or not ip.is_global:
        raise ValueError("SSH access requires one public /32 or /128; no wildcards or private IPs")
    return server, str(ip)

def execute(args, input_text=None):
    return subprocess.run(["hcloud", *args], input=input_text, capture_output=True, text=True, check=True).stdout

def main(argv=None):
    p = argparse.ArgumentParser(description="Provision an SSH-restricted, billable Hetzner bootstrap server")
    p.add_argument("action", choices=("plan", "check", "apply", "status"))
    p.add_argument("--config", default="cloud/hetzner.toml")
    p.add_argument("--approve-cost", action="store_true")
    args = p.parse_args(argv)
    try:
        server, address = configuration(args.config)
        name = server["name"]
        fw = name + "-ssh"
        rules = json.dumps([{"direction":"in","protocol":"tcp","port":"22","source_ips":[address]}])
        create = ["server","create","--name",name,"--type",server["type"],"--location",server["location"],"--image",server["image"],"--ssh-key",server["ssh_key"],"--firewall",fw]
        if args.action == "plan":
            print("Bootstrap: Ubuntu; NixOS installation is a separate, destructive operation")
            print("Inbound SSH allowed only from", address)
            print("Create firewall", fw, "then create server", name, "type", server["type"])
            return 0
        if not shutil.which("hcloud"):
            raise RuntimeError("Install Hetzner's official hcloud CLI")
        # hcloud stores its active context in its own configuration file.
        # The CLI handles authentication; environment variables are optional.
        # The read-only SSH key describe call below verifies access to that project.
        if args.action == "status":
            print(execute(["server","describe",name,"-o","json"]))
            return 0
        execute(["ssh-key","describe",server["ssh_key"],"-o","json"])
        for kind, item in (("server",name),("firewall",fw)):
            listing = json.loads(execute([kind,"list","-o","json"]))
            records = listing if isinstance(listing, list) else listing.get(kind+"s", [])
            if any(entry.get("name") == item for entry in records):
                raise RuntimeError(f"Existing {kind} named {item}; refusing to modify")
        if args.action == "check":
            print("Preflight passed. No infrastructure created.")
            return 0
        if not args.approve_cost:
            raise RuntimeError("Creating billable resources requires --approve-cost")
        execute(["firewall","create","--name",fw,"--rules-file","-"], rules)
        print(execute(create))
        print("Ubuntu bootstrap created and billing started. NixOS is NOT yet installed.")
        return 0
    except (OSError, KeyError, ValueError, RuntimeError, subprocess.CalledProcessError) as e:
        print(f"cloud: {e}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    sys.exit(main())
