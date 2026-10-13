#!/usr/bin/env bash
# Runs the real AzerothCore images + DB initialization. Heavy and networked.
# Intended for a dedicated runner; never used as a quick PR unit test.
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: $0 /nix/store/...-addon-forge-compose.yaml" >&2
  exit 2
fi
compose="$1"
if [[ ! -f "$compose" ]]; then
  echo "Compose template not found: $compose" >&2
  exit 2
fi

work_dir="$(mktemp -d)"
chmod 700 "$work_dir"
env_file="$work_dir/.env"
password="$(openssl rand -hex 32)"
printf 'FORGE_DB_PASSWORD=%s\n' "$password" > "$env_file"
chmod 600 "$env_file"
args=(compose -p forge-ci --env-file "$env_file" -f "$compose")

cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    docker "${args[@]}" ps || true
    echo 'Realm integration failed; see container status above. No secrets printed.' >&2
  fi
  docker "${args[@]}" down --remove-orphans || true
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT

docker "${args[@]}" config --quiet
docker "${args[@]}" up -d

# Don't confuse `docker compose up -d` with successful world initialization.
# On first run, client-data and world DB imports can take many minutes.
end=$((SECONDS + 1800))
while (( SECONDS < end )); do
  if docker "${args[@]}" ps --status running --services | grep -qx 'ac-authserver' \
      && docker "${args[@]}" ps --status running --services | grep -qx 'ac-worldserver'; then
    if python3 - <<'PY'
import socket
for port in (3724, 8085):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3):
            pass
    except OSError:
        raise SystemExit(1)
PY
    then
      echo 'AzerothCore authserver and worldserver are accepting local TCP connections.'
      exit 0
    fi
  fi
  if docker "${args[@]}" ps --all --status exited --services | grep -Eq '^(ac-authserver|ac-worldserver)$'; then
    echo '::error::AzerothCore exited before becoming ready' >&2
    exit 1
  fi
  sleep 15
done
echo '::error::Realm did not become ready within 30 minutes.' >&2
exit 1
