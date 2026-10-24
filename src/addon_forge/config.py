"""Local configuration; no secrets are stored here."""
from dataclasses import dataclass
from pathlib import Path
import tomllib


@dataclass(frozen=True)
class Config:
    wow_dir: Path
    wine_prefix: Path
    realm_dir: Path | None = None
    window_name: str = "World of Warcraft"
    report_timeout: int = 35
    automation_backend: str = "win32"
    wowcontrol_injector: Path | None = None
    wowcontrol_dll: Path | None = None
    wowcontrol_realm: str = ""
    release_addons_repo: Path | None = None    # wow-addons checkout (FR-15.1)
    release_website_repo: Path | None = None   # raid-website checkout (FR-15.5)


def load_config(path: Path) -> Config:
    with path.expanduser().resolve().open("rb") as fh:
        obj = tomllib.load(fh)
    client = obj.get("client", {})
    realm = obj.get("realm", {})
    release = obj.get("release", {})
    wow = client.get("wow_dir")
    if not wow:
        raise ValueError("Set [client] wow_dir in forge.toml")
    wine = client.get("wine_prefix", "~/.local/share/addon-forge/wine")
    realm_path = realm.get("source_dir")
    backend = client.get("automation_backend", "win32")
    if backend not in ("win32", "wowcontrol"):
        raise ValueError("Unknown automation backend; choose win32 or wowcontrol")
    def optional_path(name):
        value = client.get(name)
        return Path(value).expanduser().resolve() if value else None
    return Config(
        wow_dir=Path(wow).expanduser().resolve(),
        wine_prefix=Path(wine).expanduser().resolve(),
        realm_dir=Path(realm_path).expanduser().resolve() if realm_path else None,
        window_name=client.get("window_name", "World of Warcraft"),
        report_timeout=int(client.get("report_timeout", 35)),
        automation_backend=backend,
        wowcontrol_injector=optional_path("wowcontrol_injector"),
        wowcontrol_dll=optional_path("wowcontrol_dll"),
        wowcontrol_realm=client.get("wowcontrol_realm", ""),
        release_addons_repo=Path(release["addons_repo"]).expanduser().resolve() if release.get("addons_repo") else None,
        release_website_repo=Path(release["website_repo"]).expanduser().resolve() if release.get("website_repo") else None,
    )
