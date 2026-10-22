// swift-tools-version: 5.7
// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import PackageDescription

let package = Package(
    name: "EditDot",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    products: [.executable(name: "EditDot", targets: ["EditDot"])],
    targets: [.executableTarget(name: "EditDot", path: "Sources/EditDot", resources: [.process("Resources")])]
)
