import Foundation
import Observation
import OSLog
import Sparkle

@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private static let logger = Logger(subsystem: "com.branchline.git", category: "updates")

    private(set) var isEnabled = false
    private(set) var canCheck = false
    private(set) var availableVersion: String?
    private(set) var waitingForRelaunch = false

    @ObservationIgnored private weak var desk: WorkspaceTabs?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var availabilityObservation: NSKeyValueObservation?
    @ObservationIgnored private var pendingRelaunch: (() -> Void)?

    func start(desk: WorkspaceTabs) {
        guard controller == nil, Self.isConfigured(Bundle.main) else { return }
        self.desk = desk
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        do {
            try controller.updater.start()
        } catch {
            Self.logger.error("Updater could not start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.controller = controller
        isEnabled = true
        availabilityObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            let available = change.newValue ?? false
            Task { @MainActor [weak self] in self?.canCheck = available }
        }
    }

    func checkForUpdates() {
        guard let controller, controller.updater.canCheckForUpdates, !waitingForRelaunch else { return }
        controller.checkForUpdates(nil)
    }

    func resumeRelaunchIfReady() {
        guard let pendingRelaunch, desk?.updateRestartBlocker == nil else { return }
        self.pendingRelaunch = nil
        waitingForRelaunch = false
        pendingRelaunch()
    }

    private static func isConfigured(_ bundle: Bundle) -> Bool {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              isHTTPS(URL(string: feed)),
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else { return false }
        return Data(base64Encoded: key)?.count == 32
    }

    private static func isHTTPS(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "https" && url?.host?.isEmpty == false
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        availableVersion = update.displayVersionString
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        guard Self.isHTTPS(updateItem.fileURL) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "Для установки обновления требуется ссылка HTTPS.",
            ])
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip { availableVersion = nil }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard desk?.updateRestartBlocker != nil else { return false }
        pendingRelaunch = installHandler
        waitingForRelaunch = true
        return true
    }

    func standardUserDriverWillFinishUpdateSession() {
        pendingRelaunch = nil
        waitingForRelaunch = false
    }
}
