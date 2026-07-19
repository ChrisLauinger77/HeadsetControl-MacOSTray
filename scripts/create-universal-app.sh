#!/bin/bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 ARM64_ARCHIVE X86_64_ARCHIVE OUTPUT_ARCHIVE" >&2
  exit 2
fi

arm64_archive="$1"
x86_64_archive="$2"
output_archive="$3"
work_dir="$(mktemp -d)"

mkdir -p "$work_dir/arm64" "$work_dir/x86_64" "$work_dir/universal"
ditto -x -k "$arm64_archive" "$work_dir/arm64"
ditto -x -k "$x86_64_archive" "$work_dir/x86_64"

arm64_app="$work_dir/arm64/HeadsetControl-MacOSTray.app"
x86_64_app="$work_dir/x86_64/HeadsetControl-MacOSTray.app"
universal_app="$work_dir/universal/HeadsetControl-MacOSTray.app"
ditto "$arm64_app" "$universal_app"

executable_path="Contents/MacOS/HeadsetControl-MacOSTray"
lipo -create \
  "$arm64_app/$executable_path" \
  "$x86_64_app/$executable_path" \
  -output "$universal_app/$executable_path"
chmod +x "$universal_app/$executable_path"

codesign --force --deep --sign - "$universal_app"
codesign --verify --deep --strict --verbose=4 "$universal_app"
lipo "$universal_app/$executable_path" -verify_arch arm64 x86_64

ditto -c -k --sequesterRsrc --keepParent "$universal_app" "$output_archive"
