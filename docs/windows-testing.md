# Native Windows graphical WoW tests (experimental)

Addon Forge can control an **authorized, locally installed World of Warcraft 3.3.5a** client on Windows 10/11. It uses the same ForgeTestBridge as Linux, but on Windows suites run through the WoWControlSDK: the bridge report comes back as JSON in one call, with no `/reload`. SDK login and character entry are available for a marked local test copy. See the [current QA workflow](qa-workflow.md).

## Install on native Windows (PowerShell, not WSL)

For the verified local AzerothCore and OpenCode workflow, start with [Autonomous addon QA](qa-workflow.md).

Use Python 3.11 or newer, Git and the local WoW directory. You do **not** need Nix or Wine to run the local Forge client controller.

```powershell
git switch main
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -e ".[windows]"
Copy-Item forge.toml.example forge.toml
```

Edit `forge.toml`:

```toml
[client]
wow_dir = "F:/Games/World of Warcraft 3.3.5a"
window_name = "World of Warcraft"
report_timeout = 60
# wine_prefix is ignored on Windows
```

Use forward slashes in TOML Windows paths; otherwise you must escape backslashes. Keep this file out of Git. Use the native Windows Python, not WSL, when driving the Windows graphical client.

```powershell
.\.venv\Scripts\forge.exe doctor
.\.venv\Scripts\forge.exe check wow/ForgeTestBridge
.\.venv\Scripts\forge.exe deploy wow/ForgeTestBridge
.\.venv\Scripts\forge.exe deploy examples/ForgeExample
.\.venv\Scripts\forge.exe client start
```

In WoW, choose **Windowed** or **Windowed (Fullscreen)** mode; manually log into a private realm, enable the addons, enter the game world, and leave the WoW window accessible in the interactive desktop. Run:

```powershell
.\.venv\Scripts\forge.exe client screenshot .forge-runs/window.png
.\.venv\Scripts\forge.exe test --suite smoke --require-test example_frame_visible
```

With `automation_backend = "wowcontrol"` (see [the SDK section](qa-workflow.md#optional-wowcontrolsdk-backend-experimental-windows-only)) the test calls `ForgeTestBridge:RunJSON` over the PID-verified SDK pipe and checks the returned report's run id, assertions and captured Lua errors. It returns `infrastructure_error` if no matching report arrives (not a false pass). The only keyboard input left on Windows is a validated `/targetexact NAME` for peer fixtures. PNG screenshots use Pillow.

## SDK login for a private Forge test account (experimental)

This applies **only** to a separate, marked Forge test client on **Windows
native Python** with the WoWControlSDK backend. It does not modify Rising Gods
or log into public realms, and never stores passwords in `forge.local.toml`.

```powershell
cd F:\addon-forge
.\.venv\Scripts\python.exe -m pip install -e ".[windows]"
.\.venv\Scripts\forge.exe --config forge.local.toml client login save --account FORGETEST
```

The password is requested privately and saved in **Windows Credential
Manager**. Do not enter your Rising Gods credentials. Only disposable *local
test realm* accounts are supported. `agent prepare --start-client --login
--enter-character NAME` and `agent session PLAN` then launch the marked client
through the SDK injector and log in over the SDK pipe: credentials are never
typed, put on a command line or logged. The former pixel-calibrated keyboard
login (`client login calibrate`, `client start --login`) was removed.

## Security and limitations

- Windows API window discovery verifies the **running executable path**, not just the title. If more than one matching WoW client is visible, the controller refuses to pick one.
- A **foreground interactive desktop** is required. Windows services, locked sessions, UAC secure desktop, disconnected RDP sessions, and minimized game windows may block input or screenshots. Run WoW and Forge with the same permissions.
- Foreground activation is verified before sending keys. Do not use the keyboard or mouse during the short automated test.
- The current Win32 keyboard backend handles only printable ASCII commands and the **active keyboard layout** must be able to type each character. DirectX exclusive fullscreen and certain graphics backends may block ImageGrab or simulated input; choose windowed mode for testing.
- This is a first implementation with mocked Windows UI tests; **no real WoW Windows session has been exercised in CI**. Manual testing on a 3.3.5a client is required before considering native input/screenshot behavior validated.
- It does **not** configure realmlist, create an account, or connect to the remote Hetzner realm. That realm currently binds login/world ports to loopback, so use a separate secure worker/tunnel design instead of exposing game ports publicly.
