# Building Postfrau

Needs macOS 26, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). No other
dependencies.

```bash
make gen       # generate the Xcode project
make build     # app + CLI
make run
make test      # Core tests + app tests
make install   # link the CLI into your PATH
make release   # DMG in dist/
```

Set `CODESIGN_IDENTITY` to sign with a Developer ID and `NOTARY_PROFILE` to notarize. Both are
optional.
