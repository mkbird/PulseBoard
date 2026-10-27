# CliptoPulse Agent Guidelines

## Build & Distribution Rule (Mandatory)

Whenever you modify any source code (`Sources/`), resources (`Resources/`, `Sources/PulseBoard/Resources/`), or package configuration (`Package.swift`) in this repository, you **must** rebuild and update the app bundle in `dist/`:

```bash
./Scripts/build-app.sh
```

### Why this is required
- Users launch the application via `启动 CliptoPulse.command`, which opens `dist/CliptoPulse.app` directly and only runs `Scripts/build-app.sh` if `dist/CliptoPulse.app` does not exist.
- `dist/CliptoPulse.app` is tracked in this repository and must stay in sync with the latest source and resource changes (including `web_console.html`).

### Post-build checklist
1. Run `./Scripts/build-app.sh` and verify it exits with `0` and outputs the path to `dist/CliptoPulse.app`.
2. Verify `dist/CliptoPulse.app/Contents/MacOS/PulseBoard` and `dist/CliptoPulse.app/Contents/Resources/PulseBoard_PulseBoard.bundle` have been updated.
3. If `CliptoPulse` (`PulseBoard`) is currently running in the background and the user expects live changes to take effect immediately, restart `dist/CliptoPulse.app` (or inform the user to restart it).
