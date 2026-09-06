#!/bin/bash

set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "Usage: $0 ARM64_ARCHIVE X86_64_ARCHIVE OUTPUT_ARCHIVE [TAG]" >&2
  exit 2
fi

arm64_archive="$1"
x86_64_archive="$2"
output_archive="$3"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
script_dir="$(cd "$(dirname "$0")" && pwd)"
tag_arguments=()
if [ "$#" -eq 4 ]; then tag_arguments=(--tag "$4"); fi

# Validate ZIP identity before extraction, and the extracted bundles before lipo.
python3 "$script_dir/release-artifact.py" archive "$arm64_archive" ${tag_arguments[@]+"${tag_arguments[@]}"}
python3 "$script_dir/release-artifact.py" archive "$x86_64_archive" ${tag_arguments[@]+"${tag_arguments[@]}"}

mkdir -p "$work_dir/arm64" "$work_dir/x86_64" "$work_dir/universal"
ditto -x -k "$arm64_archive" "$work_dir/arm64"
ditto -x -k "$x86_64_archive" "$work_dir/x86_64"

arm64_app="$work_dir/arm64/HeadsetControl-MacOSTray.app"
x86_64_app="$work_dir/x86_64/HeadsetControl-MacOSTray.app"
universal_app="$work_dir/universal/HeadsetControl-MacOSTray.app"
python3 "$script_dir/release-artifact.py" bundle "$x86_64_app" --match-bundle "$arm64_app" ${tag_arguments[@]+"${tag_arguments[@]}"}
xcrun lipo "$arm64_app/Contents/MacOS/HeadsetControl-MacOSTray" -verify_arch arm64
xcrun lipo "$x86_64_app/Contents/MacOS/HeadsetControl-MacOSTray" -verify_arch x86_64
ditto "$arm64_app" "$universal_app"

executable_path="Contents/MacOS/HeadsetControl-MacOSTray"
xcrun lipo -create \
  "$arm64_app/$executable_path" \
  "$x86_64_app/$executable_path" \
  -output "$universal_app/$executable_path"
chmod +x "$universal_app/$executable_path"

codesign --force --deep --sign - "$universal_app"
codesign --verify --deep --strict --verbose=4 "$universal_app"
for architecture in arm64 x86_64; do
  xcrun lipo "$universal_app/$executable_path" -verify_arch "$architecture"
done

candidate_archive="$work_dir/HeadsetControl-MacOSTray.zip"
ditto -c -k --sequesterRsrc --keepParent "$universal_app" "$candidate_archive"
python3 "$script_dir/release-artifact.py" archive "$candidate_archive" --match-bundle "$arm64_app" ${tag_arguments[@]+"${tag_arguments[@]}"}
mkdir "$work_dir/final"
ditto -x -k "$candidate_archive" "$work_dir/final"
final_app="$work_dir/final/HeadsetControl-MacOSTray.app"
python3 "$script_dir/release-artifact.py" bundle "$final_app" --match-bundle "$arm64_app" ${tag_arguments[@]+"${tag_arguments[@]}"}
codesign --verify --deep --strict --verbose=4 "$final_app"
for architecture in arm64 x86_64; do
  xcrun lipo "$final_app/$executable_path" -verify_arch "$architecture"
done
cp "$candidate_archive" "$output_archive"
