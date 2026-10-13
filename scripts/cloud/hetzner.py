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
    # Keep captured output for JSON parsing. On failure, main() displays the
    # actionable stderr instead of Python's unhelpful exception repr.
    return subprocess.run(["hcloud", *args], input=input_text, capture_output=True, text=True, check=True).stdout


def find_resource(kind, name):
    """Read-only lookup for a named existing server or firewall."""
    listing = json.loads(execute([kind, "list", "-o", "json"]))
    records = listing if isinstance(listing, list) else listing.get(kind + "s", [])
    if not isinstance(records, list):
        raise RuntimeError(f"Unexpected hcloud {kind} list output; refusing to provision")
    return next((item for item in records if item.get("name") == name), None)


def validate_reusable_firewall(name, source):
    """Never reuse a firewall unless it has exactly our expected SSH rule.

    It must also be unattached to other resources. A failed previous apply
    commonly leaves this unused firewall behind.
    """
    result = json.loads(execute(["firewall", "describe", name, "-o", "json"]))
    fw = result.get("firewall", result)
    rules = fw.get("rules", [])
    expected = {"direction": "in", "protocol": "tcp",
                "port": "22", "source_ips": [source]}
    if (len(rules) != 1 or
            {key: rules[0].get(key) for key in expected} != expected or
            fw.get("applied_to")):
        raise RuntimeError(
            f"Existing firewall {name!r} is not an unattached, exact SSH-only match. "
            "Inspect it using 'hcloud firewall describe' and resolve manually."
        )

def check_type_availability(server):
    """Consult Hetzner's live per-location availability indicator.

    A True value is only a hint, not a guarantee of successful placement.
    A False value is a useful reason to stop before trying to create a server.
    """
    kind = server["type"]
    location = server["location"]
    data = json.loads(execute(["server-type", "describe", kind, "-o", "json"]))
    details = data.get("server_type", data) if isinstance(data, dict) else {}
    locations = details.get("locations")
    if not isinstance(locations, list):
        print("Warning: hcloud did not expose per-location availability; "
              "use 'hcloud server-type describe' to inspect manually.", file=sys.stderr)
        return
    for row in locations:
        # Current hcloud JSON uses locations[].name; tolerate older nested
        # locations[].location.name responses for compatibility.
        place = row.get("location", row.get("name")) if isinstance(row, dict) else None
        place_name = place.get("name") if isinstance(place, dict) else place
        if place_name != location:
            continue
        if row.get("available") is False:
            raise RuntimeError(
                f"Hetzner currently marks {kind} unavailable in {location}. "
                "See 'hcloud server-type list -o "
                "columns=name,location,location_available,location_recommended' "
                "for alternatives. No server was created."
            )
        if row.get("available") is True:
            print(f"Hetzner lists {kind} in {location} as available "
                  "(not a capacity guarantee).")
        else:
            print(f"Warning: availability of {kind} in {location} "
                  "was not provided by hcloud.")
        return
    raise RuntimeError(
        f"Hetzner does not list {kind} as supported in {location}. "
        "Choose a listed server type and location."
    )


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
        check_type_availability(server)
        if find_resource("server", name):
            raise RuntimeError(
                f"Server {name!r} already exists. Check 'hcloud server list' "
                "before retrying to avoid duplicate charges."
            )
        firewall_exists = find_resource("firewall", fw) is not None
        if firewall_exists:
            validate_reusable_firewall(fw, address)
            print(f"Pre-existing SSH-only firewall {fw} verified; safe to reuse.")
        if args.action == "check":
            print("Preflight passed. No infrastructure created.")
            return 0
        if not args.approve_cost:
            raise RuntimeError("Creating billable resources requires --approve-cost")
        if not firewall_exists:
            execute(["firewall","create","--name",fw,"--rules-file","-"], rules)
            print(f"Created SSH-only firewall: {fw}")
        try:
            print(execute(create))
        except subprocess.CalledProcessError:
            print(
                "cloud: Server creation failed. The firewall may remain. "
                "Run 'hcloud server list' and 'hcloud firewall list' "
                "before any retry.", file=sys.stderr
            )
            raise
        print("Ubuntu bootstrap created and billing started. NixOS is NOT yet installed.")
        return 0
    except subprocess.CalledProcessError as e:
        details = (e.stderr or e.stdout or "").strip()
        print(f"cloud: hcloud failed (exit {e.returncode}): "
              f"{details or 'no error details returned'}", file=sys.stderr)
        return 2
    except (OSError, KeyError, TypeError, ValueError, RuntimeError) as e:
        print(f"cloud: {e}", file=sys.stderr)
        return 2

if __name__ == "__main__":
    sys.exit(main())
