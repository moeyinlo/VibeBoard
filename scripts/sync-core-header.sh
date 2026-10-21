#!/bin/bash
# Keeps the header vendored inside the Swift package in step with the Rust core.
set -euo pipefail
cd "$(dirname "$0")/.."
cp core/crates/vibeboard-core/include/vibeboard_core.h Sources/CVibeBoardCore/include/vibeboard_core.h
echo "synced vibeboard_core.h"
