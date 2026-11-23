import Foundation

/// The hand-over of a shared item from the Share extension to the app (openspec:
/// add-share-extension, decision 6). The extension writes two files into `Share/` in the App Group
/// container both share:
///
/// - `<id>.item`: the text, in UTF-8, or a copy of the file;
/// - `<id>.json`: `{"v":1,"kind":"text"|"file","name":…,"type":…,"at":…}`, `at` in milliseconds
///   since 1970.
///
/// Both have complete file protection, so they can't be read while the phone is locked, and are
/// out of the phone's backups. The app takes the item when `kemlock://share/<id>` opens it, or on
/// its next launch or return to the front, and deletes both files; anything [maxAge] old or more
/// is deleted unread. Nothing in them names a vault: the app holds the item for whichever vault is
/// opened next.
struct SharedItemFile {
  static let appGroup = "group.com.kemlock.app"

  /// How long a shared item waits before it is deleted unread.
  static let maxAge: TimeInterval = 10 * 60

  /// The scheme of the link that opens the app on an item: `kemlock://share/<id>`.
  static let scheme = "kemlock"

  let folder: URL

  /// The hand-over folder in the App Group container; nil for a build without the group.
  static func shared() -> SharedItemFile? {
    guard let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
    return SharedItemFile(folder: base.appendingPathComponent("Share", isDirectory: true))
  }

  /// What `<id>.json` holds.
  struct Meta: Codable, Equatable {
    var v = 1
    let kind: String
    let name: String?
    let type: String?
    let at: Int64
  }

  /// Why an item could not be written or taken.
  enum Problem: Error, Equatable {
    case unreadable
    case noRoom
  }

  /// An item taken from the folder, as the app hands it to Dart.
  enum Taken: Equatable {
    case text(String, at: Int64)
    case file(path: String, name: String, size: Int64, type: String?, at: Int64)
    case refused(Problem)

    /// The map lib/platform/shared_items.dart reads.
    var channelMap: [String: Any] {
      switch self {
      case .text(let text, let at):
        return ["text": text, "at": at]
      case .file(let path, let name, let size, let type, let at):
        var map: [String: Any] = ["path": path, "name": name, "size": size, "at": at]
        if let type { map["type"] = type }
        return map
      case .refused(.unreadable):
        return ["error": "unreadable"]
      case .refused(.noRoom):
        return ["error": "noRoom"]
      }
    }
  }

  func itemURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).item") }
  func metaURL(_ id: String) -> URL { folder.appendingPathComponent("\(id).json") }

  /// Ids are UUIDs, which keeps file names inside the folder.
  static func isId(_ id: String) -> Bool { UUID(uuidString: id) != nil }

  /// The id a `kemlock://share/<id>` link names; nil for any other link.
  static func id(fromLink url: URL) -> String? {
    guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "share" else { return nil }
    let id = url.lastPathComponent
    return isId(id) ? id : nil
  }

  /// The link that opens the app on item [id].
  static func link(_ id: String) -> URL { URL(string: "\(scheme)://share/\(id)")! }

  // MARK: The extension's side

  /// Writes [text] and its description; gives the item's id. Throws, leaving neither file.
  func write(text: String, now: Date = Date(), id: String = UUID().uuidString) throws -> String {
    try prepare()
    let item = itemURL(id)
    do {
      try Data(text.utf8).write(to: item, options: [.completeFileProtection, .withoutOverwriting])
      try finish(id, Meta(kind: "text", name: nil, type: "text/plain", at: Self.millis(now)), now: now)
      return id
    } catch {
      remove(id)
      throw Self.problem(error)
    }
  }

  /// Copies the file at [source] on disk, never into memory, with its [name] and media [type];
  /// gives the item's id. Throws, leaving neither file.
  func write(fileAt source: URL, name: String, type: String?, now: Date = Date(), id: String = UUID().uuidString) throws -> String {
    try prepare()
    let item = itemURL(id)
    do {
      try FileManager.default.copyItem(at: source, to: item)
      // The copy keeps the original's dates; its age is counted from now
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete, .modificationDate: now], ofItemAtPath: item.path)
      try finish(id, Meta(kind: "file", name: Self.safeName(name), type: type, at: Self.millis(now)), now: now)
      return id
    } catch {
      remove(id)
      throw Self.problem(error)
    }
  }

  private func prepare() throws {
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      throw Self.problem(error)
    }
  }

  private func finish(_ id: String, _ meta: Meta, now: Date) throws {
    let data = try JSONEncoder().encode(meta)
    try data.write(to: metaURL(id), options: [.completeFileProtection, .withoutOverwriting])
    for var url in [itemURL(id), metaURL(id)] {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try url.setResourceValues(values)
    }
  }

  // MARK: The app's side

  /// Takes item [id]: a text is read; a file is moved into a new directory under [root], the
  /// app's own `share/` temporary directory, as Dart reads it. Both files are gone after, whatever
  /// happened. Nil when there is no such item, or it is [maxAge] old.
  func take(_ id: String, into root: URL, now: Date = Date()) -> Taken? {
    guard Self.isId(id) else { return nil }
    defer { remove(id) }
    guard let data = try? Data(contentsOf: metaURL(id)), let meta = try? JSONDecoder().decode(Meta.self, from: data),
      meta.v == 1, !Self.tooOld(meta.at, now: now)
    else { return nil }
    switch meta.kind {
    case "text":
      guard let bytes = try? Data(contentsOf: itemURL(id)), let text = String(data: bytes, encoding: .utf8) else {
        return .refused(.unreadable)
      }
      return .text(text, at: meta.at)
    case "file":
      let directory = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
      let target = directory.appendingPathComponent(Self.safeName(meta.name ?? "shared"))
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: itemURL(id), to: target)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: target.path)
        let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
        return .file(path: target.path, name: target.lastPathComponent, size: size, type: meta.type, at: meta.at)
      } catch {
        try? FileManager.default.removeItem(at: directory)
        return .refused(Self.problem(error))
      }
    default:
      return nil
    }
  }

  /// Deletes every item [maxAge] old or more, and anything else in the folder that is no item;
  /// gives the newest item left, for the app to take when no link named one.
  func sweep(now: Date = Date()) -> String? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    var newest: (id: String, at: Int64)?
    for name in names {
      let url = folder.appendingPathComponent(name)
      let id = (name as NSString).deletingPathExtension
      let ext = (name as NSString).pathExtension
      guard Self.isId(id), ext == "json" || ext == "item" else {
        try? FileManager.default.removeItem(at: url)
        continue
      }
      guard ext == "json" else {
        // An item whose description is missing was cut short; one with it is judged by it
        if !FileManager.default.fileExists(atPath: metaURL(id).path), Self.olderThanMaxAge(url, now: now) { remove(id) }
        continue
      }
      guard let data = try? Data(contentsOf: url), let meta = try? JSONDecoder().decode(Meta.self, from: data),
        !Self.tooOld(meta.at, now: now)
      else {
        remove(id)
        continue
      }
      if newest == nil || meta.at > newest!.at { newest = (id, meta.at) }
    }
    return newest?.id
  }

  /// Deletes the whole folder: every vault was erased.
  func clear() {
    try? FileManager.default.removeItem(at: folder)
  }

  private func remove(_ id: String) {
    try? FileManager.default.removeItem(at: itemURL(id))
    try? FileManager.default.removeItem(at: metaURL(id))
  }

  // MARK: Rules both sides keep

  static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

  static func tooOld(_ at: Int64, now: Date) -> Bool {
    now.timeIntervalSince1970 - TimeInterval(at) / 1000 >= maxAge
  }

  private static func olderThanMaxAge(_ url: URL, now: Date) -> Bool {
    let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    return now.timeIntervalSince(modified) >= maxAge
  }

  /// A file's name reduced to its last part, without control characters; `shared` when nothing is left.
  static func safeName(_ name: String) -> String {
    let base = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
    let clean = String(base.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init))
      .trimmingCharacters(in: .whitespaces)
    return clean.isEmpty || clean == "." || clean == ".." ? "shared" : String(clean.prefix(200))
  }

  /// Whether [error] says the storage is full.
  static func problem(_ error: Error) -> Problem {
    if let problem = error as? Problem { return problem }
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return .noRoom }
    if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return .noRoom }
    if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)
    {
      return .noRoom
    }
    return .unreadable
  }

  /// How the Share extension reads one attachment: its text, the address of a web page it is a link to, or a file.
  enum Reading: Equatable {
    case plainText
    case webLink
    case file
  }

  /// Which way to read an attachment of the registered type identifiers [types] (`public.url`, `public.file-url`,
  /// `public.plain-text`, ...), from whether it [hasSuggestedName]. A file URL, or anything with a suggested name that
  /// is not a web link, is a file, as before. Safari shares a page as `public.url` with the page title as its
  /// suggested name, which made it a file the app could not read; a `public.url` that is not a file URL is a link
  /// to read as text (plan add-sends, task 7.4).
  static func reading(types: [String], hasSuggestedName: Bool) -> Reading {
    let isFileURL = types.contains("public.file-url")
    if !isFileURL && types.contains("public.url") { return .webLink }
    if isFileURL || hasSuggestedName { return .file }
    return types.contains("public.plain-text") || types.contains("public.utf8-plain-text") ? .plainText : .file
  }

  /// The text of the web link [url] shares: its address when it is `https` with a host, else nil and the
  /// attachment is read as before. The app finds a Send link in it, or treats it as any shared text.
  static func webLinkText(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
    return url.absoluteString
  }
}
