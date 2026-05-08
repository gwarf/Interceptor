# Document domains (PRD-66)

Four bridge domains for processing files without launching the source app:

- **PDF** (PDFKit, macOS 10.4+)
- **Detect** (NSDataDetector + DDMatch, macOS 10.7+ / 12+)
- **Translate** (Translation framework, macOS 15+)
- **Thumbnail** (QuickLookThumbnailing, macOS 10.15+)

All four domains are fully background-safe; none of them require TCC consent or activate any other app.

## PDF

```bash
interceptor macos pdf info <path>
interceptor macos pdf text <path> [--page N | --range A-B] [--attributed]
interceptor macos pdf outline <path>
interceptor macos pdf annotations <path> [--page N] [--type Highlight]
interceptor macos pdf forms <path>
interceptor macos pdf forms set <path> --field <name> --value <string> [--out <out>]
interceptor macos pdf images <path>
interceptor macos pdf find <path> "<query>" [--case-sensitive]
interceptor macos pdf attributes <path>
interceptor macos pdf permissions <path>
interceptor macos pdf annotate <path> --page N --rect x,y,w,h --type Highlight --contents "..."
interceptor macos pdf strip <path> --out <out>
interceptor macos pdf merge <p1> <p2> ... --out <out>
interceptor macos pdf split <path> --pages 1-5 --out <out>
```

`text --attributed` returns rich-text runs with font and color metadata. `forms set` round-trips: the response includes the post-write `forms` shape. `merge`/`split` use `PDFDocument.write(to:)` so output PDFs preserve the source's encryption posture.

## Detect

`NSDataDetector` covers the universal Foundation surface (macOS 10.7+). The Swift `DataDetector` enum (macOS 26+) and the `DDMatch*` types (macOS 12+) light up additional semantic types.

```bash
interceptor macos detect types
interceptor macos detect run "<text>"
interceptor macos detect run "<text>" --types link,phone,address,email,calendarEvent,money,flight,shipping
interceptor macos detect file <path>
```

Available types depend on the host's macOS version. The `types` verb returns the live list rather than a hardcoded set.

## Translate (macOS 15+)

```bash
interceptor macos translate status
interceptor macos translate languages
interceptor macos translate availability --from <bcp47> --to <bcp47>
interceptor macos translate availability --to <bcp47> --sample "text"
interceptor macos translate prepare --from <bcp47> --to <bcp47>
interceptor macos translate text "<text>" --from <bcp47> --to <bcp47>
interceptor macos translate batch --to <bcp47> --json '["a","b","c"]'
interceptor macos translate file <path> --from <bcp47> --to <bcp47>
interceptor macos translate stop
```

`prepare` triggers the system download dialog when the requested language pair isn't yet installed. `text` and `batch` use `TranslationSession.init(installedSource:target:)` so they work headless without a SwiftUI host.

On macOS < 15, every verb returns a structured `{available: false, framework: "Translation", note: "..."}` payload — never `notImplemented`.

## Thumbnail

```bash
interceptor macos thumbnail <path> [--size N | WxH] [--scale N]
   [--types icon,thumbnail,lowQuality] [--save] [--out <path>]
   [--format png|jpeg|heic]
interceptor macos thumbnail batch <p1> <p2> ... [--size N]
```

`--save` uses `QLThumbnailGenerator.shared.saveBestRepresentation(for:to:contentType:)` — the low-memory variant Apple ships for File Provider Extensions. Without `--save`, the inline path uses `generateBestRepresentation` and returns a base64 data URL.

Default heuristic picks PNG when alpha matters (PDFs, icons, screenshots) and JPEG when it doesn't.
