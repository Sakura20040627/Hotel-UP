"""Use the hosted runner's preconfigured Xcode when it has the iOS 26 SDK."""
import glob
import os
import subprocess


def sdk_version(developer):
    try:
        sdk = subprocess.check_output(
            ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"],
            env={**os.environ, "DEVELOPER_DIR": developer},
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=15,
        ).strip()
        return tuple(map(int, sdk.split(".")))
    except (subprocess.SubprocessError, ValueError):
        return ()


default = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
if sdk_version(default)[:1] == (26,):
    print(default)
    raise SystemExit(0)

choices = []
for app in sorted({os.path.realpath(app) for app in glob.glob("/Applications/Xcode*.app")}):
    developer = f"{app}/Contents/Developer"
    sdk = sdk_version(developer)
    if sdk[:1] == (26,):
        choices.append((sdk, developer))

if not choices:
    raise SystemExit("No Xcode installation has the iOS 26 SDK.")
print(max(choices)[1])
