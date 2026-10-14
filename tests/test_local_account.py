"""Offline tests for local account creation; Docker client is mocked."""
from types import SimpleNamespace
import pytest
from addon_forge.local_account import create_test_account


def test_account_create_password_is_not_in_command_arguments(capsys):
    args = []
    def attach(argv, **kwargs):
        args.extend(argv)
        assert kwargs["input"] == b"account create FORGETEST VeryPrivate123\n\x10\x11"
        return SimpleNamespace(returncode=0)
    create_test_account("ForgeTest", input_password=lambda _: "VeryPrivate123",
                        attach=attach)
    assert "VeryPrivate123" not in str(args)
    assert "VeryPrivate123" not in capsys.readouterr().out


@pytest.mark.parametrize("account", ["", "hi", "two words", "-test", "a" * 20])
def test_reject_invalid_account_names(account):
    with pytest.raises(ValueError, match="Account name"):
        create_test_account(account, input_password=lambda _: "VeryPrivate123")


def test_no_plaintext_password_errors(capsys):
    def attach(argv, **kwargs):
        return SimpleNamespace(returncode=1)
    with pytest.raises(RuntimeError, match="could not be submitted"):
        create_test_account("ForgeTest", input_password=lambda _: "VeryPrivate123",
                            attach=attach)
    assert "VeryPrivate123" not in capsys.readouterr().out
