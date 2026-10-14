"""Fail-closed access to the external WoWControlSDK pipe.

An unauthenticated fixed pipe name is unsafe for passwords. The public SDK
currently creates its pipe with default DACL and doesn't expose reliable
server PID authentication in the Python connector. Therefore automatic
credential RPC is intentionally disabled until a hardened upstream build
exposes a verifiable per-session pipe and process identity.
"""
def open_verified_pipe(transport):
    raise RuntimeError(
        "WoWControlSDK named-pipe process identity is not verifiable: "
        "refusing to send local realm credentials to a fixed-name pipe. "
        "A PID-bound authenticated pipe transport is required.")
