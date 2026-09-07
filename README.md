# Postfrau

A free, native macOS HTTP client — a personal Postman replacement. Send requests, organize them into
collections, switch environments. No accounts, no cloud, no telemetry; your data is plain JSON files
in a folder you choose (put it in iCloud Drive, Dropbox or a git repo and it syncs itself).

Requires **macOS 26 (Tahoe)** or later. Swift 6 and SwiftUI, zero third-party dependencies.

## Build

```bash
Scripts/bootstrap.sh   # installs xcodegen if needed, generates Postfrau.xcodeproj
make test              # PostfrauCore unit tests + app tests
make run               # build and launch
```

## Layout

| Path | What |
|---|---|
| `Packages/PostfrauCore` | Models, persistence, HTTP executor, variable resolver, importers — pure Swift, no UI |
| `Postfrau/` | The SwiftUI app |
| `PLAN.md` | The execution plan and its phase checklist |
| `docs/decisions.md` | Decisions and deviations from the plan |
| `STATUS.md` | Current state: what works, what's next |

## License

MIT — see [LICENSE](LICENSE).
