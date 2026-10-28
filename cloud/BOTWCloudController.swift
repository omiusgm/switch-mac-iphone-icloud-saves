import UIKit
import UniformTypeIdentifiers

@MainActor @objc(BOTWCloudController)
public final class BOTWCloudController: NSObject, UIDocumentPickerDelegate {
    private static var active: BOTWCloudController?
    private let presenter: UIViewController, profile: URL, support: URL, statusURL: URL
    private var completion: (() -> Void)?
    private var folder: URL?, engine: CloudSaveEngine?, progress: UIAlertController?
    private var started = false, backgroundTask = UIBackgroundTaskIdentifier.invalid
    private let queue = DispatchQueue(label: "org.macnativegames.botw.cloud-saves")
    private let defaults = UserDefaults.standard
    private let bookmarkKey = "BOTWCloudFolderBookmark"

    @objc(prepareWithPresenter:profile:completion:)
    public static func prepare(presenter: UIViewController, profile: String, completion: @escaping () -> Void) {
        let controller = BOTWCloudController(presenter: presenter, profile: URL(fileURLWithPath: profile), completion: completion)
        active = controller; controller.begin()
    }
    private init(presenter: UIViewController, profile: URL, completion: @escaping () -> Void) {
        self.presenter = presenter; self.profile = profile; self.completion = completion
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BOTWCloud")
        statusURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("cloud-status.json")
        super.init()
    }
    private func begin() {
        if defaults.bool(forKey: "BOTWCloudChooseFolder") { chooseFolder(); return }
        if let data = defaults.data(forKey: bookmarkKey) {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                connect(url); return
            } catch { recover(error); return }
        }
        if defaults.bool(forKey: "BOTWCloudSkipSetup") { finish(); return }
        let alert = UIAlertController(title: "Сохранения iCloud", message: "Выбери папку «Zelda BOTW» в iCloud Drive один раз. Игра будет забирать сохранения перед запуском и отправлять их после сворачивания.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Выбрать папку", style: .default) { _ in self.chooseFolder() })
        alert.addAction(UIAlertAction(title: "Пока локально", style: .cancel) { _ in self.defaults.set(true, forKey: "BOTWCloudSkipSetup"); self.finish() })
        presenter.present(alert, animated: true)
    }
    private func chooseFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self; picker.allowsMultipleSelection = false; picker.title = "Zelda BOTW в iCloud Drive"
        presenter.present(picker, animated: true)
    }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        controller.dismiss(animated: true) { self.defaults.set(false, forKey: "BOTWCloudChooseFolder"); self.defaults.set(true, forKey: "BOTWCloudSkipSetup"); self.finish() }
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        controller.dismiss(animated: true) { if let url = urls.first { self.connect(url) } else { self.finish() } }
    }
    nonisolated private static func validFolder(_ root: URL) -> Bool {
        let marker = root.appendingPathComponent("ZeldaCloud.json")
        var valid = false, error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: marker, options: [], error: &error) { url in
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
               let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                valid = value["format"] == CloudSaveEngine.format && value["game"] == CloudSaveEngine.game && value["version"] == CloudSaveEngine.version
            }
        }
        return error == nil && valid
    }
    private func connect(_ url: URL) {
        if let old = folder { old.stopAccessingSecurityScopedResource() }; folder = nil; engine = nil
        guard url.startAccessingSecurityScopedResource() else { recover(CloudFailure("Нет доступа к выбранной папке. Выбери её ещё раз.")); return }
        folder = url
        showProgress()
        let profile = self.profile, support = self.support, status = self.statusURL
        queue.async {
            do {
                guard Self.validFolder(url) else { throw CloudFailure("Выбери папку «Zelda BOTW», созданную на Mac. Если она ещё загружается из iCloud, подожди немного.") }
                let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                let worker = try CloudSaveEngine(profile: profile, cloud: url, stateURL: support.appendingPathComponent("state.json"), backups: support.appendingPathComponent("backups"), device: "iPhone")
                DispatchQueue.main.async {
                    self.defaults.set(bookmark, forKey: self.bookmarkKey); self.defaults.set(false, forKey: "BOTWCloudChooseFolder"); self.defaults.set(false, forKey: "BOTWCloudSkipSetup"); self.engine = worker
                }
                let report = try worker.startup()
                Self.writeStatus(report, phase: "startup", url: status, device: worker.deviceID)
                DispatchQueue.main.async { self.dismissProgress { self.handle(report) } }
            } catch { DispatchQueue.main.async { self.dismissProgress { self.recover(error) } } }
        }
    }
    private func showProgress() {
        let alert = UIAlertController(title: "Сохранения iCloud", message: "Загружаем и проверяем прогресс…", preferredStyle: .alert)
        progress = alert; presenter.present(alert, animated: true)
    }
    private func dismissProgress(_ block: @escaping () -> Void) {
        if let alert = progress { progress = nil; alert.dismiss(animated: false, completion: block) } else { block() }
    }
    private func handle(_ report: CloudReport) {
        guard report.status == "conflict" else { finish(); return }
        let alert = UIAlertController(title: "Какой прогресс продолжить?", message: "На устройствах появились разные сохранения. Все копии останутся в истории.", preferredStyle: .alert)
        for choice in report.choices {
            let formatter = DateFormatter(); formatter.dateFormat = "dd.MM HH:mm"
            let date = ISO8601DateFormatter().date(from: choice.created).map { formatter.string(from: $0) } ?? choice.created
            alert.addAction(UIAlertAction(title: choice.device + " · " + date, style: .default) { _ in self.resolve(choice.id) })
        }
        alert.addAction(UIAlertAction(title: "Играть с локальной копией", style: .cancel) { _ in self.finish() })
        presenter.present(alert, animated: true)
    }
    private func resolve(_ id: String) {
        guard let worker = engine else { finish(); return }
        showProgress(); let status = statusURL
        queue.async {
            do {
                let report = try worker.resolve(id); Self.writeStatus(report, phase: "resolved", url: status, device: worker.deviceID)
                DispatchQueue.main.async { self.dismissProgress { self.finish() } }
            } catch { DispatchQueue.main.async { self.dismissProgress { self.recover(error) } } }
        }
    }
    private func recover(_ error: Error) {
        let alert = UIAlertController(title: "iCloud пока недоступен", message: error.localizedDescription + " Локальные сохранения сохранены.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Повторить", style: .default) { _ in if let url = self.folder { self.connect(url) } else { self.chooseFolder() } })
        alert.addAction(UIAlertAction(title: "Выбрать папку", style: .default) { _ in self.chooseFolder() })
        alert.addAction(UIAlertAction(title: "Играть локально", style: .cancel) { _ in self.finish() })
        presenter.present(alert, animated: true)
    }
    private func finish() {
        guard !started else { return }; started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in DispatchQueue.main.async { self.publish() } }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in DispatchQueue.main.async { self.checkResume() } }
        let block = completion; completion = nil; block?()
    }
    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }
    private func publish() {
        guard let worker = engine, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Сохранения iCloud") {
            worker.cancel(); DispatchQueue.main.async { self.endBackgroundTask() }
        }
        let status = statusURL
        queue.async {
            do { Self.writeStatus(try worker.publish(), phase: "background", url: status, device: worker.deviceID) }
            catch { Self.writeStatus(CloudReport(status: "pending", message: error.localizedDescription), phase: "background", url: status, device: worker.deviceID) }
            DispatchQueue.main.async { self.endBackgroundTask() }
        }
    }
    private func checkResume() {
        guard let worker = engine, presenter.presentedViewController == nil else { return }
        let status = statusURL
        queue.async {
            guard let report = try? worker.checkRemote() else { return }
            Self.writeStatus(report, phase: "resume", url: status, device: worker.deviceID)
            if report.status == "remote-update" || report.status == "conflict" {
                DispatchQueue.main.async {
                    guard self.presenter.presentedViewController == nil else { return }
                    let alert = UIAlertController(title: "Есть прогресс с другого устройства", message: "Чтобы загрузить его, закрой игру и открой снова. Сохранения не заменяются во время работающей игры.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Закрыть игру", style: .default) { _ in exit(0) })
                    alert.addAction(UIAlertAction(title: "Продолжить здесь", style: .cancel))
                    self.presenter.present(alert, animated: true)
                }
            }
        }
    }
    nonisolated private static func writeStatus(_ report: CloudReport, phase: String, url: URL, device: String) {
        guard let data = try? JSONEncoder().encode(report), var value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        value["phase"] = phase; value["device_id"] = device; value["updated"] = CloudSaveEngine.now()
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}
