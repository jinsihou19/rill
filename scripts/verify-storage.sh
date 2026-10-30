#!/bin/zsh
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
swift build
binary_directory="$(swift build --show-bin-path)"
mkdir -p build
swiftc -I "$binary_directory" -L "$binary_directory" -lRillCore Sources/RillApp/Persistence.swift scripts/verify-storage.swift -o build/verify-storage
build/verify-storage
