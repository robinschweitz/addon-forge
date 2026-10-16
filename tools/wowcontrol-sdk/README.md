# Forge build of WoWControlSDK

Addon Forge runs the WoWControlSDK (`.forge-tools/wowcontrol-sdk/source`, a
git checkout that `.gitignore` keeps out of this repository) with local
changes. `forge-sdk.patch` holds all of them, against upstream commit
`6cda5ac734dba8016a7ef30ae7bcad602472c1e2`:

- **Idle logout hook** (`hooks/IdleLogoutHook.cpp`, `DllMain.cpp`,
  `hooks/Hooks.cpp`, `CMakeLists.txt`): blocks the idle logout of a client
  started through the injector (see `docs/agent-playbook.md`).
- **Lua RPC** (`rpc/handlers/core/LuaRpc.cpp`): Forge's `lua.evaluate` changes.
- **Two clients side by side** (`ipc/CommandPipe.cpp`,
  `runtime/events/EventPipe.cpp`, `runtime/window/WindowService.cpp`): each
  WoW process serves `\\.\pipe\WowGameCommand-<pid>` and
  `\\.\pipe\WowGameEvent-<pid>`, and the window lookup no longer falls back
  to another process's game window (it compared a thread ID with the process
  ID, so it always took the first WoW window). Without this a second injected
  client never answered its pipe. Forge connects to the per-process pipe and
  falls back to the shared name for older builds; the injector is run with
  `--no-pipe --wait`, since it cannot name a per-process pipe in advance.

Apply and build (Visual Studio 2022, CMake):

```bash
git -C .forge-tools/wowcontrol-sdk/source apply ../../../tools/wowcontrol-sdk/forge-sdk.patch
```

```bash
cmake --build .forge-tools/wowcontrol-sdk/source/build --config Release
```

The DLL and injector land in `.forge-tools/wowcontrol-sdk/source/bin/release/`,
the paths `forge.local.toml` points to.
