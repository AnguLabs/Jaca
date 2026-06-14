#!/usr/bin/env bash
set -euo pipefail

# Regenerates the Swift protobuf + gRPC client stubs for the companion link from
# proto/companion.proto into Sources/Core/Companion/Generated/. The generated files
# are checked in, so the Xcode build never depends on protoc — run this only when
# the .proto changes.
#
# Tooling:
#   brew install protobuf swift-protobuf        # protoc + protoc-gen-swift
#   # grpc-swift 1.x plugin (matches the GRPC runtime pinned in project.yml):
#   git clone --depth 1 --branch 1.27.5 https://github.com/grpc/grpc-swift.git /tmp/grpc-swift-1x
#   (cd /tmp/grpc-swift-1x && swift build -c release --product protoc-gen-grpc-swift)
#
# Override the plugin path with GRPC_SWIFT_PLUGIN if you built it elsewhere.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Sources/Core/Companion/Generated"
GRPC_PLUGIN="${GRPC_SWIFT_PLUGIN:-/tmp/grpc-swift-1x/.build/release/protoc-gen-grpc-swift}"

if [[ ! -x "$GRPC_PLUGIN" ]]; then
  echo "error: grpc-swift plugin not found at $GRPC_PLUGIN" >&2
  echo "       build it (see header) or set GRPC_SWIFT_PLUGIN." >&2
  exit 1
fi

mkdir -p "$OUT"

protoc \
  --proto_path="$ROOT/proto" \
  --plugin=protoc-gen-grpc-swift="$GRPC_PLUGIN" \
  --swift_opt=Visibility=Public \
  --swift_out="$OUT" \
  --grpc-swift_opt=Visibility=Public,Client=true,Server=false \
  --grpc-swift_out="$OUT" \
  "$ROOT/proto/companion.proto"

echo "Generated Swift stubs in $OUT"
