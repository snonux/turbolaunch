#!/usr/bin/env bash
# Renders the README screenshots (docs/screenshots/*.png) from the Linux build
# at phone size, with the demo apps. Needs xvfb-run.
set -euo pipefail
cd "$(dirname "$0")/.."
# flutter test only runs integration tests from integration_test/, and the CI
# run of that directory must not pick this one up, so it is copied in for now.
tmp=integration_test/readme_shots_tmp_test.dart
trap 'rm -f "$tmp"' EXIT
cp tool/readme_shots_test.dart "$tmp"
xvfb-run -a flutter test "$tmp" -d linux --dart-define=SHOTS="$PWD/docs/screenshots"
ls -l docs/screenshots
