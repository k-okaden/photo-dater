import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 定数

let jst = TimeZone(identifier: "Asia/Tokyo")!
var jstCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = jst
    return c
}()

let mediaExtensions: Set<String> = [
    "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp",
    "dng", "cr2", "cr3", "nef", "nrw", "arw", "raf", "orf", "rw2", "pef", "srw",
    "mov", "mp4", "m4v",
]

// MARK: - モデル

enum FolderStatus: Equatable {
    case ready
    case running
    case done(Int)
    case failed(String)
}

struct FolderItem: Identifiable {
    let id = UUID()
    let url: URL
    var files: [URL]
    var date: Date?          // JST の 00:00 を保持(日付部分のみ使用)
    let fromName: Bool       // フォルダ名から自動判定できたか
    var status: FolderStatus = .ready

    var name: String { url.lastPathComponent }
}

struct FileDateInfo: Identifiable {
    var id: String { path }
    let path: String
    let current: String
}

/// フォルダ名先頭の yymmdd を日付として解釈する(例: "240503", "240503_運動会")
func parseFolderDate(_ name: String) -> Date? {
    guard let m = name.wholeMatch(of: /^(\d{2})(\d{2})(\d{2})(?:\D.*)?$/) else { return nil }
    guard let yy = Int(m.1), let mm = Int(m.2), let dd = Int(m.3) else { return nil }
    let comps = DateComponents(year: 2000 + yy, month: mm, day: dd)
    guard comps.isValidDate(in: jstCalendar), let d = jstCalendar.date(from: comps) else { return nil }
    return d
}

func listMedia(in dir: URL) -> [URL] {
    let fm = FileManager.default
    let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles])) ?? []
    return items
        .filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func subdirectories(of dir: URL) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                              options: [.skipsHiddenFiles])) ?? []
    return items
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

// MARK: - ファイル名変更

enum Renamer {
    static let defaultTemplate = "{yymmdd}_{nn}_{name}"
    static let variablesHelp = "{yymmdd} {yyyy} {yy} {mm} {dd} 日付 / {nn} {nnn} 連番 / {name} 元ファイル名 / {folder} フォルダ名"

    /// 同じ日付・パターンで付けた接頭辞を外す(再実行で「240503_01_240503_01_…」にならないように)
    static func originalBase(_ base: String, date: Date) -> String {
        let yymmdd = format(date, "%02d%02d%02d", short: true)
        if let m = base.wholeMatch(of: /(\d{6})_\d{2,}_(.+)/), String(m.1) == yymmdd { return String(m.2) }
        return base
    }

    static func format(_ date: Date, _ f: String, short: Bool) -> String {
        let c = jstCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: f, short ? c.year! % 100 : c.year!, c.month!, c.day!)
    }

    /// 各ファイルの新しいファイル名(拡張子込み)を返す。
    /// RAW+JPEG のように拡張子違いで同じ名前のファイルは同じ連番にする。
    static func plan(files: [URL], date: Date, folder: String, template: String) -> [URL: String] {
        var numbers: [String: Int] = [:]
        var result: [URL: String] = [:]
        for url in files {
            let base = originalBase(url.deletingPathExtension().lastPathComponent, date: date)
            let n: Int
            if let existing = numbers[base.lowercased()] { n = existing } else {
                n = numbers.count + 1
                numbers[base.lowercased()] = n
            }
            var s = template
            let vars: [(String, String)] = [
                ("{yymmdd}", format(date, "%02d%02d%02d", short: true)),
                ("{yyyy}", format(date, "%04d", short: false)),
                ("{yy}", String(format: "%02d", jstCalendar.component(.year, from: date) % 100)),
                ("{mm}", String(format: "%02d", jstCalendar.component(.month, from: date))),
                ("{dd}", String(format: "%02d", jstCalendar.component(.day, from: date))),
                ("{nnn}", String(format: "%03d", n)),
                ("{nn}", String(format: "%02d", n)),
                ("{name}", base),
                ("{folder}", folder),
            ]
            for (k, v) in vars { s = s.replacingOccurrences(of: k, with: v) }
            s = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            if s.trimmingCharacters(in: .whitespaces).isEmpty { s = base }
            let ext = url.pathExtension
            result[url] = ext.isEmpty ? s : s + "." + ext
        }
        return result
    }

    /// 2段階(一時名 → 新名)でリネームし、名前の入れ替わりでも衝突しないようにする。
    /// 戻り値: 新しいURLの一覧(元の順番)とエラー
    static func apply(_ files: [URL], plan: [URL: String]) -> (files: [URL], errors: [String]) {
        let fm = FileManager.default
        var errors: [String] = []
        var temps: [(orig: URL, temp: URL, target: String)] = []
        var output = files

        for url in files {
            guard let target = plan[url], target != url.lastPathComponent else { continue }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".photodater-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: url, to: temp)
                temps.append((url, temp, target))
            } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for t in temps {
            let dir = t.orig.deletingLastPathComponent()
            var dest = dir.appendingPathComponent(t.target)
            // 無関係な既存ファイルと被ったら _2, _3… を付ける
            var i = 2
            let stem = (t.target as NSString).deletingPathExtension, ext = (t.target as NSString).pathExtension
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent(ext.isEmpty ? "\(stem)_\(i)" : "\(stem)_\(i).\(ext)")
                i += 1
            }
            do {
                try fm.moveItem(at: t.temp, to: dest)
                if let idx = output.firstIndex(of: t.orig) { output[idx] = dest }
            } catch {
                // 失敗したら元の名前に戻す
                try? fm.moveItem(at: t.temp, to: t.orig)
                errors.append("\(t.orig.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (output, errors)
    }
}

// MARK: - exiftool

enum ExifTool {
    static let path: String? = [
        "/opt/homebrew/bin/exiftool", "/usr/local/bin/exiftool", "/usr/bin/exiftool",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// 引数は -@ - で標準入力から渡す(ファイル数が多くても安全)
    static func run(_ args: [String]) -> Result {
        guard let path else { return Result(status: -1, stdout: "", stderr: "exiftool が見つかりません") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-@", "-"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch {
            return Result(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        inPipe.fileHandleForWriting.write(args.joined(separator: "\n").data(using: .utf8)!)
        try? inPipe.fileHandleForWriting.close()
        // 出力を先に読み切ってからwait(パイプ詰まり防止)
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: outData, as: UTF8.self),
                      stderr: String(decoding: errData, as: UTF8.self))
    }

    static func readDates(_ files: [URL]) -> [String: String] {
        guard !files.isEmpty else { return [:] }
        let r = run(["-j", "-q", "-m", "-DateTimeOriginal", "-CreateDate", "-OffsetTimeOriginal"] + files.map(\.path))
        guard let data = r.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for obj in arr {
            guard let src = obj["SourceFile"] as? String else { continue }
            let dto = (obj["DateTimeOriginal"] as? String) ?? (obj["CreateDate"] as? String)
            var s = dto ?? "(なし)"
            if dto != nil, let off = obj["OffsetTimeOriginal"] as? String { s += " " + off }
            map[src] = s
        }
        return map
    }

    /// 撮影日を書き込む。dateString は "yyyy:MM:dd HH:mm:ss"
    static func writeDates(_ files: [URL], dateString: String, keepBackup: Bool) -> Result {
        var args = ["-m", "-P", "-api", "QuickTimeUTC=1",
                    "-AllDates=\(dateString)+09:00",
                    "-OffsetTimeOriginal=+09:00",
                    "-OffsetTime=+09:00",
                    "-OffsetTimeDigitized=+09:00"]
        if !keepBackup { args.append("-overwrite_original") }
        return run(args + files.map(\.path))
    }
}

// MARK: - アプリ状態

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [FolderItem] = []
    @Published var time: Date = jstCalendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: 12, minute: 0))!
    @Published var keepBackup = false
    @Published var showConfirm = false
    @Published var isRunning = false
    @Published var finished = false
    @Published var preview: [UUID: [FileDateInfo]] = [:]
    @Published var notice: String?
    // リネーム設定は次回起動時にも引き継ぐ
    @Published var renameEnabled = UserDefaults.standard.bool(forKey: "renameEnabled") {
        didSet { UserDefaults.standard.set(renameEnabled, forKey: "renameEnabled") }
    }
    @Published var template = UserDefaults.standard.string(forKey: "renameTemplate") ?? Renamer.defaultTemplate {
        didSet { UserDefaults.standard.set(template, forKey: "renameTemplate") }
    }

    /// テンプレートの見本(先頭フォルダの先頭ファイル、なければダミー)
    var templateExample: String {
        let item = items.first { $0.date != nil && !$0.files.isEmpty }
        let date = item?.date ?? jstCalendar.date(from: DateComponents(year: 2024, month: 5, day: 3))!
        let file = item?.files.first ?? URL(fileURLWithPath: "/IMG_1234.jpg")
        return Renamer.plan(files: [file], date: date, folder: item?.name ?? "240503", template: template)[file] ?? ""
    }

    var readyItems: [FolderItem] { items.filter { $0.date != nil && !$0.files.isEmpty } }
    var missingDateCount: Int { items.filter { $0.date == nil && !$0.files.isEmpty }.count }
    var totalFiles: Int { readyItems.reduce(0) { $0 + $1.files.count } }

    func add(urls: [URL]) {
        var skipped: [String] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                skipped.append(url.lastPathComponent); continue
            }
            let files = listMedia(in: url)
            // 写真が直下にない親フォルダなら、中のサブフォルダを個別に追加
            if files.isEmpty {
                let subs = subdirectories(of: url).filter { !listMedia(in: $0).isEmpty }
                if !subs.isEmpty { add(urls: subs); continue }
            }
            if items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { continue }
            let d = parseFolderDate(url.lastPathComponent)
            items.append(FolderItem(url: url, files: files, date: d, fromName: d != nil))
        }
        finished = false
        if !skipped.isEmpty { notice = "フォルダ以外はスキップしました: " + skipped.joined(separator: ", ") }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func dateString(for day: Date) -> String {
        let d = jstCalendar.dateComponents([.year, .month, .day], from: day)
        let t = jstCalendar.dateComponents([.hour, .minute], from: time)
        return String(format: "%04d:%02d:%02d %02d:%02d:00", d.year!, d.month!, d.day!, t.hour!, t.minute!)
    }

    func displayString(for day: Date) -> String {
        let d = jstCalendar.dateComponents([.year, .month, .day], from: day)
        let t = jstCalendar.dateComponents([.hour, .minute], from: time)
        return String(format: "%04d/%02d/%02d %02d:%02d JST", d.year!, d.month!, d.day!, t.hour!, t.minute!)
    }

    func openConfirm() {
        preview = [:]
        showConfirm = true
        let targets = readyItems
        Task.detached {
            for item in targets {
                let map = ExifTool.readDates(item.files)
                let infos = item.files.map { FileDateInfo(path: $0.path, current: map[$0.path] ?? "(読み取り不可)") }
                await MainActor.run { self.preview[item.id] = infos }
            }
        }
    }

    func renamePlan(for item: FolderItem) -> [URL: String]? {
        guard renameEnabled, let date = item.date else { return nil }
        return Renamer.plan(files: item.files, date: date, folder: item.name, template: template)
    }

    func execute() {
        isRunning = true
        let targets = readyItems.map { (item: $0, ds: dateString(for: $0.date!), plan: renamePlan(for: $0)) }
        let backup = keepBackup
        Task.detached {
            for (item, ds, plan) in targets {
                await self.setStatus(item.id, .running)
                let r = ExifTool.writeDates(item.files, dateString: ds, keepBackup: backup)
                let updated = Int(r.stdout.firstMatch(of: /(\d+) image files? updated/)?.1 ?? "") ?? 0
                var errs = r.stderr.split(separator: "\n").filter { $0.hasPrefix("Error") }.map(String.init)
                if r.status != 0 && updated == 0 && errs.isEmpty {
                    errs.append(r.stderr.isEmpty ? "不明なエラー" : r.stderr)
                }
                // 撮影日の書き込み後にファイル名を変更
                if let plan {
                    let renamed = Renamer.apply(item.files, plan: plan)
                    errs += renamed.errors.map { "リネーム失敗 " + $0 }
                    await self.setFiles(item.id, renamed.files)
                }
                await self.setStatus(item.id, errs.isEmpty ? .done(updated)
                                     : .failed("\(updated)件書き込み / " + errs.joined(separator: "\n")))
            }
            await MainActor.run {
                self.isRunning = false
                self.finished = true
                self.showConfirm = false
            }
        }
    }

    private func setStatus(_ id: UUID, _ s: FolderStatus) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].status = s }
    }

    private func setFiles(_ id: UUID, _ files: [URL]) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].files = files }
    }
}

// MARK: - 画面

struct ContentView: View {
    @StateObject var model = AppModel()
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if ExifTool.path == nil {
                Text("exiftool が見つかりません。ターミナルで `brew install exiftool` を実行してください。")
                    .foregroundStyle(.white).padding(8).frame(maxWidth: .infinity).background(.red)
            }

            if model.items.isEmpty {
                dropZone
            } else {
                folderList
            }

            Divider()
            renameBar
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .environment(\.timeZone, jst)
        .environment(\.locale, Locale(identifier: "ja_JP"))
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls: urls); return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted && !model.items.isEmpty {
                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .sheet(isPresented: $model.showConfirm) { ConfirmView(model: model) }
        .alert(model.notice ?? "", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") {}
        }
    }

    var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 52)).foregroundStyle(.secondary)
            Text("写真フォルダをここにドラッグ&ドロップ").font(.title2)
            Text("フォルダ名が yymmdd(例: 240503)なら、その日の撮影日として記録します\n複数フォルダOK・日付でない名前は手動で指定できます")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("フォルダを選択…") { model.openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                .padding(20)
        )
    }

    var folderList: some View {
        List {
            ForEach($model.items) { $item in
                FolderRow(item: $item, model: model)
            }
            .onDelete { model.items.remove(atOffsets: $0) }
        }
    }

    var renameBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("ファイル名も変更", isOn: $model.renameEnabled)
                TextField(Renamer.defaultTemplate, text: $model.template)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!model.renameEnabled)
                Button("初期値") { model.template = Renamer.defaultTemplate }
                    .disabled(!model.renameEnabled)
            }
            if model.renameEnabled {
                HStack {
                    Text("例: ").foregroundStyle(.secondary) + Text(model.templateExample).bold()
                    Spacer()
                    Text(Renamer.variablesHelp).font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var footer: some View {
        HStack(spacing: 16) {
            Button { model.openPanel() } label: { Label("追加", systemImage: "plus") }
            Button("全部クリア") { model.items.removeAll(); model.finished = false }
                .disabled(model.items.isEmpty || model.isRunning)

            Spacer()

            HStack(spacing: 4) {
                Text("時刻")
                DatePicker("", selection: $model.time, displayedComponents: .hourAndMinute).labelsHidden()
                Text("JST (+09:00)").foregroundStyle(.secondary)
            }
            Toggle("バックアップを残す", isOn: $model.keepBackup)
                .help("ONにすると元ファイルを「ファイル名_original」として残します")

            Button {
                model.openConfirm()
            } label: {
                Text("確認して書き込む…").padding(.horizontal, 6)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.readyItems.isEmpty || model.isRunning || ExifTool.path == nil)
        }
        .padding(12)
    }
}

struct FolderRow: View {
    @Binding var item: FolderItem
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline)
                Text(item.files.isEmpty ? "写真が見つかりません" : "\(item.files.count) ファイル")
                    .font(.caption).foregroundStyle(item.files.isEmpty ? .red : .secondary)
            }
            Spacer()

            statusView

            if let date = item.date {
                if item.fromName {
                    Text("フォルダ名から").font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.2)))
                }
                DatePicker("", selection: Binding(get: { date }, set: { item.date = $0 }),
                           displayedComponents: .date)
                    .labelsHidden().frame(width: 130)
            } else {
                Text("日付が不明").foregroundStyle(.orange)
                Button("日付を指定") { item.date = jstCalendar.startOfDay(for: Date()) }
            }

            Button {
                model.items.removeAll { $0.id == item.id }
            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var statusView: some View {
        switch item.status {
        case .ready: EmptyView()
        case .running: ProgressView().controlSize(.small)
        case .done(let n): Label("\(n)件 完了", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let msg):
            Label("エラー", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(msg)
        }
    }
}

struct ConfirmView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("この内容で撮影日を書き込みます").font(.title2).bold()
            Text("\(model.readyItems.count) フォルダ / \(model.totalFiles) ファイル" +
                 (model.keepBackup ? "(バックアップあり)" : "(元ファイルを直接上書き)") +
                 (model.renameEnabled ? " ・ ファイル名も変更: \(model.template)" : ""))
                .foregroundStyle(model.keepBackup ? Color.secondary : Color.orange)
            if model.missingDateCount > 0 {
                Text("※ 日付未指定の \(model.missingDateCount) フォルダは対象外です").foregroundStyle(.orange)
            }

            List {
                ForEach(model.readyItems) { item in
                    let plan = model.renamePlan(for: item).map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.path, $0.value) }) }
                    DisclosureGroup {
                        if let infos = model.preview[item.id] {
                            ForEach(infos) { f in
                                HStack {
                                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                                    if let newName = plan?[f.path],
                                       newName != (f.path as NSString).lastPathComponent {
                                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                        Text(newName).foregroundStyle(.blue).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(f.current).foregroundStyle(.secondary).monospacedDigit()
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(model.displayString(for: item.date!)).monospacedDigit()
                                }
                                .font(.callout)
                            }
                        } else {
                            HStack { ProgressView().controlSize(.small); Text("現在の撮影日を読み込み中…") }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(.blue)
                            Text(item.name).bold()
                            Text("\(item.files.count) ファイル").foregroundStyle(.secondary)
                            Spacer()
                            Text("→ " + model.displayString(for: item.date!)).monospacedDigit().bold()
                        }
                    }
                }
            }
            .frame(minHeight: 300)

            HStack {
                Spacer()
                Button("キャンセル") { model.showConfirm = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRunning)
                Button {
                    model.execute()
                } label: {
                    if model.isRunning {
                        HStack { ProgressView().controlSize(.small); Text("書き込み中…") }
                    } else {
                        Text("書き込む")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isRunning)
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .environment(\.timeZone, jst)
    }
}

// MARK: - エントリポイント

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PhotoDaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("撮影日セッター") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
