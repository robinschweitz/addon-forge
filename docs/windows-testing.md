# Native Windows graphical WoW tests (experimental)

Addon Forge can control an **authorized, locally installed World of Warcraft 3.3.5a** client on Windows 10/11. It shares the Linux ForgeTestBridge and SavedVariables testing protocol. This is desktop automation, **not unattended login**: start the client, log in manually with a disposable test character and enable `ForgeTestBridge` before testing.

## Install on native Windows (PowerShell, not WSL)

Use Python 3.11 or newer, Git and the local WoW directory. You do **not** need Nix or Wine to run the local Forge client controller.

```powershell
git switch feat/native-windows-wow-testing
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

The test opens WoW chat, sends only `/forge ...` and `/reload`, then checks a matching `WTF/Account/*/SavedVariables/ForgeTestBridge.lua` report after reload. It returns `infrastructure_error` if no matching report appears (not a false pass). PNG screenshots use Pillow.

## Optional auto-login for a private Forge test account (experimental)

This workflow applies **only** to a separate, marked Forge test client on
**Windows native Python**. It does not modify Rising Gods or log into public
realms, and never stores passwords in `forge.local.toml`.

Install the optional Windows dependencies and make sure the test client is in
**windowed mode** with a stable size (e.g. 1280x720). From PowerShell:

```powershell
cd F:\addon-forge
.\.venv\Scripts\python.exe -m pip install -e ".[windows]"
.\.venv\Scripts\forge.exe --config forge.local.toml client login save --account FORGETEST
```

The password is requested privately and saved using **Windows Credential
Manager** through the Windows keyring backend. Do not enter your Rising Gods
credentials. Only disposable *local test realm* accounts are supported.

**One-time visual calibration:** Start the copied test WoW client **normally**
and wait at the account/password login screen. Make sure both fields are
empty and the window is not changing size. Run:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml client login calibrate
```

Follow four prompts, placing the mouse over two distinct, **static,
high-contrast login-panel features** (not fields, passwords or animated
background), then the center of the account field, then the password field.
Move the mouse to the requested spot and press Enter in PowerShell for each.
Forge saves only two tiny image patches and four locations in the test-client
folder as `.addon-forge-login-calibration.json`, **never the password**.

Close WoW, then start with automatic credential entry:

```powershell
.\.venv\Scripts\forge.exe --config forge.local.toml client start --login
```

Forge refuses to type unless the new WoW.exe process and its visible window
match the configured path and its login panel matches the calibration in
three consecutive observations. It rechecks the panel after focusing it
and before typing the password. If the screen is unexpected or the game
window resolution has changed, it stops **without typing credentials**.
Do not use the keyboard/mouse during automatic login. This submits the
account/password form; **realm selection and character selection remain
manual**. Automatic login isn't tested on a live client yet.

Security limitations: visual recognition is heuristic, not a proof of
game state. Only use disposable private-realm passwords. This command
cannot run on a locked Windows session, and does not support unattended
Windows service operation. The user can revoke stored credentials via
Windows Credential Manager. To recalibrate, delete only the calibration
JSON file in the separate test client's root; no game files are removed.

## Security and limitations

- Windows API window discovery verifies the **running executable path**, not just the title. If more than one matching WoW client is visible, the controller refuses to pick one.
- A **foreground interactive desktop** is required. Windows services, locked sessions, UAC secure desktop, disconnected RDP sessions, and minimized game windows may block input or screenshots. Run WoW and Forge with the same permissions.
- Foreground activation is verified before sending keys. Do not use the keyboard or mouse during the short automated test.
- The current Win32 keyboard backend handles only printable ASCII commands and the **active keyboard layout** must be able to type each character. DirectX exclusive fullscreen and certain graphics backends may block ImageGrab or simulated input; choose windowed mode for testing.
- This is a first implementation with mocked Windows UI tests; **no real WoW Windows session has been exercised in CI**. Manual testing on a 3.3.5a client is required before considering native input/screenshot behavior validated.
- It does **not** configure realmlist, automatically log in, create an account, or connect to the remote Hetzner realm. That realm currently binds login/world ports to loopback, so use a separate secure worker/tunnel design instead of exposing game ports publicly.
