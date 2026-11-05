"""Print the developer directory for the lowest eligible installed Xcode."""

import os
from pathlib import Path
import subprocess
import sys

from native_contract import CONTRACT, selected_xcode, validate_xcode


def select_xcode(applications):
    candidates = []
    # Resolve aliases such as Xcode.app and Xcode_27.2.0.app before probing.
    for app in sorted({path.resolve() for path in applications.glob("Xcode*.app")}):
        developer = app / "Contents/Developer"
        if not (developer / "usr/bin/xcodebuild").is_file():
            continue
        try:
            xcode = selected_xcode(env={**os.environ, "DEVELOPER_DIR": str(developer)})
            candidates.append((validate_xcode(xcode), developer))
        except (ValueError, subprocess.CalledProcessError) as error:
            print(f"Skipping {app.name}: {error}", file=sys.stderr)
    if not candidates:
        minimum = CONTRACT["minimum_xcode"]
        raise ValueError(f"No Xcode {minimum['version']} ({minimum['build']}) or newer in {applications}")
    return min(candidates)[1]


if __name__ == "__main__":
    try:
        print(select_xcode(Path("/Applications")))
    except ValueError as error:
        sys.exit(str(error))
