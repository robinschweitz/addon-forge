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


def load_config(path: Path) -> Config:
    with path.expanduser().resolve().open("rb") as fh:
        obj = tomllib.load(fh)
    client = obj.get("client", {})
    realm = obj.get("realm", {})
    wow = client.get("wow_dir")
    if not wow:
        raise ValueError("Set [client] wow_dir in forge.toml")
    wine = client.get("wine_prefix", "~/.local/share/addon-forge/wine")
    realm_path = realm.get("source_dir")
    return Config(
        wow_dir=Path(wow).expanduser().resolve(),
        wine_prefix=Path(wine).expanduser().resolve(),
        realm_dir=Path(realm_path).expanduser().resolve() if realm_path else None,
        window_name=client.get("window_name", "World of Warcraft"),
        report_timeout=int(client.get("report_timeout", 35)),
    )
