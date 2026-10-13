"""Exercise the semantic Compose validator without Docker/Nix installed."""
import copy
import importlib.util
from pathlib import Path

module_path = Path(__file__).resolve().parents[1] / "scripts/ci/check_compose.py"
spec = importlib.util.spec_from_file_location("check_compose", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def valid_example():
    connection = "ac-database;3306;root;ci-placeholder-not-a-secret;acore_auth"
    return {"services": {
        "ac-database": {"environment": {"MYSQL_ROOT_PASSWORD": "ci-placeholder-not-a-secret"},
                        "volumes": [{"type": "volume", "target": "/var/lib/mysql"}]},
        "ac-client-data": {},
        "ac-db-import": {"environment": {"AC_LOGIN_DATABASE_INFO": connection},
                         "depends_on": {"ac-database": {"condition": "service_healthy"}}},
        "ac-authserver": {"environment": {"AC_LOGIN_DATABASE_INFO": connection},
                          "depends_on": {"ac-db-import": {"condition": "service_completed_successfully"}},
                          "ports": [{"target": 3724, "published": "3724", "host_ip": "127.0.0.1"}]},
        "ac-worldserver": {"environment": {"AC_LOGIN_DATABASE_INFO": connection},
                           "depends_on": {"ac-db-import": {"condition": "service_completed_successfully"}},
                           "ports": [{"target": 8085, "published": "8085", "host_ip": "127.0.0.1"}]},
    }}


def test_good_compose():
    assert module.validate(valid_example()) == []


def test_rejects_exposed_realm_port():
    bad = copy.deepcopy(valid_example())
    bad["services"]["ac-worldserver"]["ports"][0]["host_ip"] = "0.0.0.0"
    assert any("127.0.0.1" in reason for reason in module.validate(bad))


def test_rejects_secret_interpolation_failure():
    bad = copy.deepcopy(valid_example())
    bad["services"]["ac-database"]["environment"]["MYSQL_ROOT_PASSWORD"] = "${FORGE_DB_PASSWORD}"
    assert any("interpolated" in reason for reason in module.validate(bad))


def test_rejects_nonpersistent_database():
    bad = copy.deepcopy(valid_example())
    bad["services"]["ac-database"]["volumes"] = []
    assert any("persistent volume" in reason for reason in module.validate(bad))


def test_rejects_bad_import_order():
    bad = copy.deepcopy(valid_example())
    bad["services"]["ac-worldserver"]["depends_on"] = {}
    assert any("worldserver" in reason for reason in module.validate(bad))
