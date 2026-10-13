#!/bin/bash
# Hardware-free regression test against the production Swift capture wrapper.
set -euo pipefail
cd "$(dirname "$0")/../.."
probe_dir=$(mktemp -d /private/tmp/vebevoice-lifecycle.XXXXXX)
trap 'rm -rf "$probe_dir"' EXIT
xcrun clang -c Tests/AudioCaptureLifecycle/fake.c -I Sources/CoreAudioCaptureSupport/include -o "$probe_dir/fake.o"
xcrun swiftc -module-cache-path "$probe_dir/cache" \
    -import-objc-header Sources/CoreAudioCaptureSupport/include/CoreAudioCaptureSupport.h \
    Sources/VebeVoice/Services/DirectCoreAudioInput.swift \
    Tests/AudioCaptureLifecycle/main.swift "$probe_dir/fake.o" -o "$probe_dir/probe"
"$probe_dir/probe"
