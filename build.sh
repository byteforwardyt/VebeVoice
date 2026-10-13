#!/bin/bash

# Unsigned Debug build of VebeVoice.
#
# Usage:
#   ./build.sh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "${PROJECT_DIR}"
exec xcodebuild -project VebeVoice.xcodeproj -scheme VebeVoice -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
