// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "interceptor-bridge",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle for in-app auto-update. The bridge polls the appcast,
        // prompts the user when a new pkg is available, and hands the
        // download off to the macOS installer.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "interceptor-bridge",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            // helper subprocess lives in Sources/InterceptorVDHelper —
            // exclude from the main bridge target since it has its own
            // entry point and a separate clean-process design (Lumen pattern).
            // No SwiftPM resource bundling — see scripts/build-bridge.sh, which
            // copies model resources directly into the .app's Contents/Resources/.
            // SwiftPM-generated resource bundles (TargetName_TargetName.bundle)
            // lack an Info.plist and codesign rejects them as nested bundles
            // when the outer .app is signed.
            exclude: ["InterceptorVDHelper", "Resources"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("SoundAnalysis"),
                .linkedFramework("Vision"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("SensitiveContentAnalysis"),
                .linkedFramework("HealthKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                // HTML overlays (OverlayDomain WKWebView mode)
                .linkedFramework("WebKit"),
                // SpriteKit overlays (Titans + scene-script)
                .linkedFramework("SpriteKit"),
                // Apple Events / TCC consent (AEDeterminePermissionToAutomateTarget)
                .linkedFramework("Carbon"),
                // PRD-66 — personal data and distribution surfaces.
                // PDFKit: PdfDomain (PDFDocument/PDFPage/PDFAnnotation/PDFOutline/PDFSelection).
                .linkedFramework("PDFKit"),
                // QuickLookThumbnailing: ThumbnailDomain (QLThumbnailGenerator).
                .linkedFramework("QuickLookThumbnailing"),
                // Translation: TranslateDomain (TranslationSession, LanguageAvailability — macOS 15+).
                .linkedFramework("Translation"),
                // LocalAuthentication: AuthDomain (LAContext.evaluatePolicy).
                .linkedFramework("LocalAuthentication"),
                // EventKit: CalendarDomain + RemindersDomain (EKEventStore).
                .linkedFramework("EventKit"),
                // Contacts: ContactsDomain (CNContactStore).
                .linkedFramework("Contacts"),
                // AppIntents: AppIntentDomain + InterceptorAppIntents declarations (macOS 13+).
                .linkedFramework("AppIntents"),
                // UserNotifications: NotificationsDomain UN extension (UNUserNotificationCenter).
                .linkedFramework("UserNotifications"),
                // Photos: PhotosDomain (PHPhotoLibrary, PHAsset, PHFetchOptions).
                .linkedFramework("Photos"),
                // MapKit: MapsDomain (MKLocalSearch, MKDirections).
                .linkedFramework("MapKit"),
                // CoreLocation: LocationDomain (CLLocationManager, CLGeocoder).
                .linkedFramework("CoreLocation"),
                // MusicKit: MusicDomain (catalog macOS 12+; library + ApplicationMusicPlayer macOS 14+).
                .linkedFramework("MusicKit"),
                // DataDetection: DetectDomain uses Foundation NSDataDetector by default;
                // the modern Swift surface (DDMatch* macOS 12+, DataDetector macOS 26+) lives
                // in the DataDetection module which is auto-imported on macOS 12+.
                .linkedFramework("DataDetection"),
                // .app bundle layout: Contents/MacOS/<bin> needs to find
                // Contents/Frameworks/Sparkle.framework at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // tiny clean-process helper that creates a CGVirtualDisplay
        // and holds it alive until SIGTERM. Lives in its own process so
        // that AppKit/SCK/etc framework state doesn't poison the
        // CGVirtualDisplay → WindowServer registration.
        .executableTarget(
            name: "interceptor-vd-helper",
            path: "Sources/InterceptorVDHelper",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
        .testTarget(
            name: "InterceptorBridgeTests",
            dependencies: ["interceptor-bridge"],
            path: "Tests/InterceptorBridgeTests"
        )
    ]
)
