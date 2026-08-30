// CalendarBridge — pulls EventKit and Photos data out of macOS as JSON.
//
// Run it as a .app bundle via `open -a`, never as a bare command-line binary.
// macOS attributes a permission request from a CLI process to its responsible parent
// (the terminal, or the editor that spawned it), which has no usage description for
// these services, so the request fails silently with no dialog at all.
//
//   CalendarBridge calendar <out.json>
//   CalendarBridge photos <from yyyy-MM-dd> <to yyyy-MM-dd> <outDir> <out.json> [maxEdge]
//   CalendarBridge photos-stat <log.txt>
//
// `open` gives no stdout, so every mode writes its result to a file the caller polls.

import EventKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

let cal = Calendar.current
let dayF = DateFormatter(); dayF.dateFormat = "yyyy-MM-dd"
let minF = DateFormatter(); minF.dateFormat = "HH:mm"
let stampF = DateFormatter(); stampF.dateFormat = "yyyy-MM-dd HH:mm"
let nameF = DateFormatter(); nameF.dateFormat = "yyyy-MM-dd HHmm"

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func write(_ obj: [String: Any], to path: String) throws {
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}

// ── Calendars and reminders ───────────────────────────────────────
func askEK(_ what: String, _ fn: (@escaping (Bool, Error?) -> Void) -> Void) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    fn { granted, _ in ok = granted; sem.signal() }
    if sem.wait(timeout: .now() + 90) == .timedOut {
        FileHandle.standardError.write("\(what): no response\n".data(using: .utf8)!)
        return false
    }
    return ok
}

func hex(_ c: CGColor?) -> String {
    guard let comps = c?.components, comps.count >= 3 else { return "#888888" }
    return String(format: "#%02X%02X%02X", Int(comps[0] * 255), Int(comps[1] * 255), Int(comps[2] * 255))
}

func runCalendar(out: String) throws {
    let store = EKEventStore()
    let calOK = askEK("calendar") { store.requestFullAccessToEvents(completion: $0) }
    let remOK = askEK("reminders") { store.requestFullAccessToReminders(completion: $0) }
    guard calOK else { die("calendar access denied", 3) }
    if !remOK { FileHandle.standardError.write("no reminder access\n".data(using: .utf8)!) }

    var o: [String: Any] = [:]
    let cals = store.calendars(for: .event)
    o["calendars"] = cals.map { c -> [String: Any] in
        // `writable` matters: subscribed holiday feeds are read-only and editing must be blocked.
        ["id": c.calendarIdentifier, "title": c.title, "source": c.source.title,
         "color": hex(c.cgColor), "writable": c.allowsContentModifications,
         "sourceType": String(describing: c.source.sourceType.rawValue)]
    }

    var comps = DateComponents(); comps.year = 2026; comps.month = 7; comps.day = 1
    let from = cal.date(from: comps)!
    let to = cal.date(byAdding: .day, value: 120, to: from)!
    let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
    o["events"] = events.map { e -> [String: Any] in
        ["title": e.title ?? "", "date": dayF.string(from: e.startDate),
         "time": e.isAllDay ? NSNull() : minF.string(from: e.startDate) as Any,
         "endDate": dayF.string(from: e.endDate),
         "endTime": e.isAllDay ? NSNull() : minF.string(from: e.endDate) as Any,
         "cal": e.calendar.calendarIdentifier, "allDay": e.isAllDay]
    }

    let lists = store.calendars(for: .reminder)
    o["lists"] = lists.map { ["title": $0.title, "source": $0.source.title] }
    func stamp(_ d: Date?) -> Any { d.map { stampF.string(from: $0) } ?? NSNull() }
    let rsem = DispatchSemaphore(value: 0)
    var rems: [[String: Any]] = []
    store.fetchReminders(matching: store.predicateForReminders(in: lists)) { rs in
        for r in rs ?? [] {
            // Three dates that mean different things. The completion date is only when a
            // script processed the item; the due date may be a real deadline or a copy of
            // the capture time; the creation date is when the thought actually arrived.
            rems.append(["title": r.title ?? "", "list": r.calendar.title, "done": r.isCompleted,
                         "created": stamp(r.creationDate),
                         "due": stamp(r.dueDateComponents.flatMap { cal.date(from: $0) }),
                         "completed": stamp(r.completionDate),
                         "notes": r.notes ?? ""])
        }
        rsem.signal()
    }
    _ = rsem.wait(timeout: .now() + 90)
    o["reminders"] = rems

    try write(o, to: out)
    print("\(cals.count) calendars · \(events.count) events · \(rems.count) reminders")
}

// ── Photos ────────────────────────────────────────────────────────
func requestPhotos() -> PHAuthorizationStatus {
    let sem = DispatchSemaphore(value: 0)
    var status: PHAuthorizationStatus = .notDetermined
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { s in status = s; sem.signal() }
    _ = sem.wait(timeout: .now() + 90)
    return status
}

func runPhotos(fromS: String, toS: String, outDir: String, out: String, maxEdge: Int) throws {
    guard let from = dayF.date(from: fromS), let toDay = dayF.date(from: toS) else {
        die("dates must be yyyy-MM-dd", 2)
    }
    let to = cal.date(byAdding: .day, value: 1, to: toDay)!   // end date is inclusive
    let status = requestPhotos()
    guard status == .authorized || status == .limited else { die("photo access denied", 3) }

    let opts = PHFetchOptions()
    opts.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate < %@ AND mediaType == %d",
                                 from as NSDate, to as NSDate, PHAssetMediaType.image.rawValue)
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let assets = PHAsset.fetchAssets(with: opts)

    let dir = URL(fileURLWithPath: outDir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let mgr = PHImageManager.default()
    let ropts = PHImageRequestOptions()
    ropts.isSynchronous = true
    ropts.deliveryMode = .highQualityFormat
    ropts.isNetworkAccessAllowed = true      // fetch originals that live only in iCloud
    ropts.version = .current

    var items: [[String: Any]] = []
    var failed = 0
    assets.enumerateObjects { asset, i, _ in
        guard let created = asset.creationDate else { return }
        var data: Data?
        mgr.requestImageDataAndOrientation(for: asset, options: ropts) { d, _, _, _ in data = d }
        guard let raw = data, let src = CGImageSourceCreateWithData(raw as CFData, nil) else {
            failed += 1; return
        }
        // Downscale straight from the source. requestImage would route through NSImage on
        // macOS, costing quality and mangling orientation; ImageIO decodes HEIC and applies
        // the orientation transform in one step.
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else {
            failed += 1; return
        }
        let name = "\(nameF.string(from: created))-\(String(format: "%03d", i)).jpg"
        let url = dir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { failed += 1; return }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { failed += 1; return }

        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        items.append(["created": stampF.string(from: created), "file": name, "bytes": bytes,
                      "w": cg.width, "h": cg.height,
                      "screenshot": asset.mediaSubtypes.contains(.photoScreenshot),
                      "favorite": asset.isFavorite])
    }

    try write(["photos": items, "from": fromS, "to": toS, "dir": outDir, "failed": failed], to: out)
    let mb = Double(items.reduce(0) { $0 + (($1["bytes"] as? Int) ?? 0) }) / 1_048_576
    print(String(format: "exported %d photos (%.1f MB)%@", items.count, mb,
                 failed > 0 ? " · \(failed) failed" : ""))
}

/// Counts what the library holds without exporting anything. Useful when a date range comes
/// back empty and the cause could be permission, sync, or genuinely no photos.
func runPhotosStat(logPath: String) {
    var log: [String] = []
    defer { try? log.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
    let status = requestPhotos()
    let names: [PHAuthorizationStatus: String] = [
        .notDetermined: "notDetermined", .restricted: "restricted", .denied: "denied",
        .authorized: "authorized", .limited: "limited (selected photos only)",
    ]
    log.append("photo access: \(names[status] ?? "unknown")")

    let all = PHFetchOptions()
    all.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
    let imgs = PHAsset.fetchAssets(with: .image, options: all)
    log.append("visible photos: \(imgs.count)")
    if imgs.count > 0 {
        let first = imgs.object(at: 0).creationDate
        let last = imgs.object(at: imgs.count - 1).creationDate
        log.append("range: \(first.map { stampF.string(from: $0) } ?? "?") .. \(last.map { stampF.string(from: $0) } ?? "?")")
        var byDay: [String: Int] = [:]
        let cutoff = cal.date(byAdding: .day, value: -60, to: Date())!
        imgs.enumerateObjects { a, _, _ in
            guard let c = a.creationDate, c >= cutoff else { return }
            byDay[dayF.string(from: c), default: 0] += 1
        }
        log.append("days shot in the last 60: \(byDay.count)")
        for k in byDay.keys.sorted().suffix(20) { log.append("   \(k)  \(byDay[k]!)") }
    }
}

// ── Entry point ───────────────────────────────────────────────────
let a = CommandLine.arguments
guard a.count >= 2 else {
    die("usage: CalendarBridge calendar <out.json> | photos <from> <to> <outDir> <out.json> [maxEdge] | photos-stat <log>", 2)
}
do {
    switch a[1] {
    case "calendar":
        guard a.count >= 3 else { die("missing out.json", 2) }
        try runCalendar(out: a[2])
    case "photos":
        guard a.count >= 6 else { die("photos <from> <to> <outDir> <out.json> [maxEdge]", 2) }
        try runPhotos(fromS: a[2], toS: a[3], outDir: a[4], out: a[5],
                      maxEdge: a.count > 6 ? (Int(a[6]) ?? 1400) : 1400)
    case "photos-stat":
        guard a.count >= 3 else { die("photos-stat <log>", 2) }
        runPhotosStat(logPath: a[2])
    default:
        die("unknown mode: \(a[1])", 2)
    }
} catch {
    die("failed: \(error)", 1)
}
