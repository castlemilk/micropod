#!/bin/sh
set -eu
out=$1
mkdir -p "$out"
# This type precedes unrelated progress parsing in the production source.
sed -n '1,/^}/p' Sources/MicropodCore/Services/ImagePullFailure.swift > "$out/ImagePullFailure.swift"
xcrun swiftc -O -parse-as-library -module-cache-path "$out/cache" -emit-library -static -emit-module \
  -module-name MicropodCore -emit-module-path "$out/MicropodCore.swiftmodule" -o "$out/libMicropodCore.a" \
  Sources/MicropodCore/CLI/MicropodError.swift "$out/ImagePullFailure.swift"
xcrun swiftc -O -module-cache-path "$out/cache" -I "$out" -L "$out" -lMicropodCore -o "$out/transport" \
  Sources/MicropodRuntime/Engines/DockerClient.swift "$(dirname "$0")/Transport.swift"
