"""Select the newest iOS 26 SDK with a compatible installed simulator."""
import glob
import json
import os
import subprocess
import sys


def xcrun(developer, *args):
    return subprocess.check_output(
        ["xcrun", *args],
        env={**os.environ, "DEVELOPER_DIR": developer},
        stderr=subprocess.DEVNULL,
        text=True,
    )


choices = []
for app in glob.glob("/Applications/Xcode*.app"):
    developer = f"{app}/Contents/Developer"
    try:
        sdk = xcrun(developer, "--sdk", "iphoneos", "--show-sdk-version").strip()
        runtimes = json.loads(xcrun(developer, "simctl", "list", "runtimes", "available", "-j"))
    except (subprocess.CalledProcessError, ValueError):
        continue
    versions = {
        item["version"] for item in runtimes["runtimes"]
        if ".iOS-" in item["identifier"] and item.get("isAvailable", True)
    }
    print(f"{app}: SDK {sdk}, available runtimes {sorted(versions)}", file=sys.stderr)
    if sdk.startswith("26."):
        components = tuple(map(int, sdk.split(".")))
        exact = any(tuple(map(int, v.split(".")))[:2] == components[:2] for v in versions)
        choices.append((exact, components, developer))

if not choices:
    raise SystemExit("No Xcode installation has the iOS 26 SDK.")
print(max(choices)[2])
