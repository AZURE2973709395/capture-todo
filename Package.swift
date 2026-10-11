// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenTodoCapture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ScreenTodoCapture", targets: ["ScreenTodoCapture"]),
        .library(name: "ScreenTodoCaptureCore", targets: ["ScreenTodoCaptureCore"])
    ],
    dependencies: [],
    targets: [
        .target(name: "ScreenTodoCaptureCore"),
        .executableTarget(
            name: "ScreenTodoCapture",
            dependencies: [
                "ScreenTodoCaptureCore"
            ],
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "ScreenTodoCaptureTests",
            dependencies: [
                "ScreenTodoCapture",
                "ScreenTodoCaptureCore"
            ]
        )
    ]
)
