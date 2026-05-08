# Distribution domains (PRD-66)

Four bridge surfaces for getting Interceptor verbs out into Siri/Shortcuts/Spotlight, posting OS-level notifications, sharing files via AirDrop/Mail/Messages, and resolving map queries.

## AppIntents

The bridge bundle ships **23 declared `AppIntent` types**, **9 `AppEntity` types** (with `EntityQuery` backings), and **3 `AppEnum` types**. Once `Interceptor-bridge.app` is installed and registered with `lsregister -f`, the intents become discoverable from the Shortcuts.app, Spotlight, and Siri.

Runtime introspection lives in `interceptor macos appintent`:

```bash
interceptor macos appintent list                           # 11 phrase-bound shortcuts
interceptor macos appintent registered                     # all 23 declared intents
interceptor macos appintent donate <intent-id>             # acknowledges a donation
interceptor macos appintent update-parameters              # AppShortcutsProvider.updateAppShortcutParameters()
interceptor macos appintent supports                       # framework + macOS gate
```

Declared intents (full list):

| Intent | Category | Routes to |
|---|---|---|
| ActivateAppIntent | System | `app activate` |
| ScreenshotAppIntent / ScreenshotDisplayIntent | System | `screenshot --app` / `screenshot --display` |
| ReadAppTreeIntent | Accessibility | `tree --app` |
| ClipboardReadIntent / ClipboardWriteIntent | System | `clipboard read/write` |
| DispatchAppleScriptIntent | System | `intent dispatch --bundle ... --script ...` |
| OCRAppIntent | Vision | `vision text --app` |
| ExtractEntitiesIntent | Language | `nlp entities` |
| AppleIntelligencePromptIntent | AI | `ai prompt` |
| StartTranscriptionIntent / StopTranscriptionIntent | Speech | `listen start` / `listen stop` |
| ReadPdfIntent | Documents | `pdf text` |
| CreateCalendarEventIntent | Calendar | `calendar create` |
| CreateReminderIntent | Reminders | `reminders create` |
| AirDropFileIntent | Sharing | `share airdrop` |
| PostNotificationIntent | System | `notifications post` |
| BiometricConfirmIntent | Security | `auth confirm` |
| TranslateTextIntent | Language | `translate text --to ...` |
| ExportPhotoIntent | Photos | `photos export` |
| SearchMapsIntent | Maps | `maps search` |
| GetCurrentLocationIntent | Location | `location current` |
| PlaySongIntent | Music | `music play --song` |
| GenerateThumbnailIntent | Documents | `thumbnail` |

Entities (`InstalledAppEntity`, `CalendarEntity`, `EventEntity`, `ReminderListEntity`, `ReminderEntity`, `ContactEntity`, `PHAssetEntity`, `SongEntity`, `LocaleEntity`) each provide a `defaultQuery` that calls back into the matching domain. Enums: `PriorityEnum`, `ScreenshotFormatEnum`, `LanguageEnum`.

The 11 phrase-bound `AppShortcut` entries declared in `InterceptorAppShortcuts.appShortcuts` are what surface in Shortcuts.app and "Hey Siri, …".

## Maps (MapKit)

```bash
interceptor macos maps search "<query>" [--region lat,lng,latSpan,lngSpan]
   [--types address,pointOfInterest,physicalFeature]
   [--poi-categories restaurant,cafe,gym]
   [--limit N]
interceptor macos maps complete "<partial>"               # MKLocalSearchCompleter
interceptor macos maps directions --from "<addr-or-coords>" --to "<addr-or-coords>"
   [--transport auto|walking|transit|any] [--requests-alternates]
interceptor macos maps eta --from "..." --to "..." [--transport <mode>]
interceptor macos maps mapitem-open <map-item-id>          # opens Maps.app
interceptor macos maps reverse <lat,lng>                   # CLGeocoder reverse
```

`search` returns `MKMapItem` objects with cached IDs (e.g. `B-1`); pass those IDs to `directions --from <id>` and `mapitem-open <id>` to avoid re-geocoding.

## Share (NSSharingService)

```bash
interceptor macos share services [--for <path>]            # live registered names
interceptor macos share airdrop <path>[,<path>...] [--recipient "<handle>"]
interceptor macos share email <path>[,...] [--to a@x,b@y] [--subject "..."] [--body "..."]
interceptor macos share message <path>[,...] [--to <handle>[,<handle>...]] [--body "..."]
interceptor macos share reading-list <url>
interceptor macos share desktop-picture <image-path>
interceptor macos share named <service-name> <path>[,...]
interceptor macos share text "<text>" --service <name>
interceptor macos share url <url> --service <name>
```

`share services` enumerates live names by probing `NSSharingService.sharingServices(forItems:)` against a sentinel URL and a sentinel string, then deduplicating.

## Notifications (UNUserNotificationCenter extension)

The existing `notifications tail` and `notifications log` continue to surface `DistributedNotificationCenter` events. PRD-66 adds the modern `UNUserNotificationCenter` surface as new sub-verbs on the same domain:

```bash
# Authorization
interceptor macos notifications status
interceptor macos notifications request --options alert,sound,badge,provisional,criticalAlert
interceptor macos notifications settings

# Posting + scheduling
interceptor macos notifications post --title "..." --body "..."
   [--subtitle "..."] [--sound default|critical|<soundName>] [--badge N]
   [--user-info '<json>'] [--category <id>] [--thread <id>]
   [--interruption active|passive|timeSensitive]
   [--attachment <path>[,<id>=<path>...]]
interceptor macos notifications schedule-after --seconds N [--repeats] --title "..." --body "..."
interceptor macos notifications schedule-at --date <ISO8601> [--repeats] --title "..." --body "..."
interceptor macos notifications schedule-cron --components weekday=3,hour=14 [--repeats] --title "..." --body "..."

# Lifecycle
interceptor macos notifications cancel <identifier>
interceptor macos notifications cancel-all
interceptor macos notifications pending
interceptor macos notifications delivered
interceptor macos notifications dismiss <identifier>
interceptor macos notifications dismiss-all

# Categories + actions
interceptor macos notifications categories list
interceptor macos notifications categories register --identifier <id> --actions '<json>' [--intent-identifiers a,b]
interceptor macos notifications categories clear

# Badge
interceptor macos notifications badge <N>
interceptor macos notifications badge clear
```

`UNLocationNotificationTrigger` is iOS-only — the bridge surfaces a structured "macOS does not support location triggers via UserNotifications; schedule via `interceptor macos calendar create --alarm` with EKAlarm proximity instead" if requested.
