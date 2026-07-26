#!/usr/bin/env bash
# Builds two side-by-side APKs (original vs JNI-patched saf_stream) with a
# benchmark screen wired in, so both can be installed on the same device at
# once and compared.
#
# Usage:
#   Put this script in the same folder as:
#     saf_stream-main.zip       (original)
#     saf_stream-main-jni.zip   (JNI-patched)
#   then run:
#     ./build_bench_apks.sh
#
# Output:
#   ./bench_build/saf_stream_bench_orig.apk
#   ./bench_build/saf_stream_bench_jni.apk
#
# Requires: flutter CLI on PATH, unzip.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ORIG_ZIP="saf_stream-main.zip"
JNI_ZIP="saf_stream-main-jni.zip"
WORK_DIR="$SCRIPT_DIR/bench_build"
BENCH_ASSETS_DIR="$SCRIPT_DIR/bench_assets"

for f in "$ORIG_ZIP" "$JNI_ZIP"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: expected $f in $SCRIPT_DIR" >&2
    exit 1
  fi
done

if [[ ! -f "$BENCH_ASSETS_DIR/benchmark_page.dart" || ! -f "$BENCH_ASSETS_DIR/bench_main.dart" ]]; then
  echo "Error: expected benchmark_page.dart and bench_main.dart in $BENCH_ASSETS_DIR" >&2
  echo "(these are the two files provided alongside this script)" >&2
  exit 1
fi

if ! command -v flutter >/dev/null 2>&1; then
  echo "Error: 'flutter' not found on PATH" >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

# variant name -> (zip file, app id suffix, human label)
declare -A ZIP_FOR=( [orig]="$ORIG_ZIP" [jni]="$JNI_ZIP" )
declare -A APPID_SUFFIX=( [orig]="bench_orig" [jni]="bench_jni" )
declare -A LABEL_FOR=( [orig]="ORIG" [jni]="JNI" )

for variant in orig jni; do
  echo "=================================================================="
  echo "Building variant: $variant"
  echo "=================================================================="

  zip_file="${ZIP_FOR[$variant]}"
  appid_suffix="${APPID_SUFFIX[$variant]}"
  label="${LABEL_FOR[$variant]}"
  project_dir="$WORK_DIR/$variant"

  mkdir -p "$project_dir"
  echo "Unzipping $zip_file..."
  unzip -q "$zip_file" -d "$project_dir"

  # The zip contains a single top-level folder (e.g. saf_stream-main/) --
  # find it so this works regardless of the exact folder name inside.
  plugin_root="$(find "$project_dir" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  example_dir="$plugin_root/example"

  if [[ ! -d "$example_dir" ]]; then
    echo "Error: could not find example/ under $plugin_root" >&2
    exit 1
  fi

  # --- Drop in the benchmark page + entry point ---
  cp "$BENCH_ASSETS_DIR/benchmark_page.dart" "$example_dir/lib/benchmark_page.dart"
  cp "$BENCH_ASSETS_DIR/bench_main.dart" "$example_dir/lib/bench_main.dart"
  sed -i.bak "s/BENCH_BUILD_LABEL/$label/" "$example_dir/lib/bench_main.dart"
  rm -f "$example_dir/lib/bench_main.dart.bak"

  # --- Give each variant a distinct applicationId so both can be installed
  #     at once, and a distinct app label so they're distinguishable on the
  #     home screen / recents. ---
  gradle_kts="$example_dir/android/app/build.gradle.kts"
  gradle_groovy="$example_dir/android/app/build.gradle"
  if [[ -f "$gradle_kts" ]]; then
    sed -i.bak "s/applicationId = \"com.fluttercavalry.saf_stream_example\"/applicationId = \"com.fluttercavalry.saf_stream_example.$appid_suffix\"/" "$gradle_kts"
    rm -f "$gradle_kts.bak"
  elif [[ -f "$gradle_groovy" ]]; then
    sed -i.bak "s/applicationId \"com.fluttercavalry.saf_stream_example\"/applicationId \"com.fluttercavalry.saf_stream_example.$appid_suffix\"/" "$gradle_groovy"
    rm -f "$gradle_groovy.bak"
  else
    echo "Warning: could not find app/build.gradle(.kts) to patch applicationId for $variant" >&2
  fi

  manifest="$example_dir/android/app/src/main/AndroidManifest.xml"
  if [[ -f "$manifest" ]]; then
    sed -i.bak "s/android:label=\"saf_stream_example\"/android:label=\"SAF Bench ($label)\"/" "$manifest"
    rm -f "$manifest.bak"
  fi

  # --- Fetch deps and build ---
  (
    cd "$example_dir"
    echo "Running flutter pub get ($variant)..."
    flutter pub get
    echo "Building APK ($variant)..."
    flutter build apk --release -t lib/bench_main.dart
  )

  built_apk="$example_dir/build/app/outputs/flutter-apk/app-release.apk"
  if [[ ! -f "$built_apk" ]]; then
    echo "Error: expected APK not found at $built_apk" >&2
    exit 1
  fi
  cp "$built_apk" "$WORK_DIR/saf_stream_bench_${variant}.apk"
  echo "Built: $WORK_DIR/saf_stream_bench_${variant}.apk"
done

echo
echo "=================================================================="
echo "Done. Install both on the same device:"
echo "  adb install -r $WORK_DIR/saf_stream_bench_orig.apk"
echo "  adb install -r $WORK_DIR/saf_stream_bench_jni.apk"
echo "=================================================================="
