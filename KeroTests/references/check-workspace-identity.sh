#!/bin/bash
set -euo pipefail
products=build/DerivedData/Build/Products/Debug
module_flags=()
for module in build/DerivedData/Build/Intermediates.noindex/GeneratedModuleMaps/TreeSitter*.modulemap; do
    case "$module" in *Queries*|*Client*) continue ;; esac
    module_flags+=(-Xcc "-fmodule-map-file=$PWD/$module")
done
xcrun swiftc -parse-as-library -swift-version 5 \
    -I "$products" -I "$products/include" \
    -I Vendor/STTextView/Sources/STObjCLandShim/include \
    "${module_flags[@]}" "$products/Kero Dev.app/Contents/MacOS/kero.debug.dylib" \
    -Xlinker -rpath -Xlinker "$PWD/$products/Kero Dev.app/Contents/MacOS" \
    -o build/check-workspace-identity KeroTests/check-workspace-identity.swift
build/check-workspace-identity "$@"
