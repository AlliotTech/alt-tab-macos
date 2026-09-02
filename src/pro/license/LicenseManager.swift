import Foundation

class LicenseManager {
    static let keychainService = "\(App.bundleIdentifier).license"
    static let defaultsSuiteName = "\(App.bundleIdentifier).license"

    static let shared: LicenseManager = {
        let keychain = SystemKeychain(service: keychainService)
        return LicenseManager(
            clock: SystemClock(),
            keychain: keychain,
            api: RemoteLicenseClient(baseUrl: Endpoints.licenseApiBaseUrl, keychain: keychain),
            defaults: UserDefaults(suiteName: defaultsSuiteName)!
        )
    }()

    static let trialDuration = 14
    private static let revalidationInterval: TimeInterval = 30 * 24 * 60 * 60 // 30 days
    static let keychainKeyAccount = "licenseKey"
    static let keychainInstanceAccount = "instanceId"
    static let keychainVariantAccount = "variantId"
    static let customerEmailKey = "customerEmail"
    /// Variant slugs that grant a Lifetime license (no version cutoff, ever).
    /// Everything else is regular Pro and may appear in `versionLimitedVariants`.
    static let lifetimeVariants: Set<String> = ["pro_lifetime"]
    /// Maps version-limited variant slugs to their max supported version.
    /// When a Pro variant needs a cutoff, add: "variant_slug": "X.Y.Z".
    static let versionLimitedVariants: [String: String] = [:]

    let clock: Clock
    let keychain: Keychain
    let api: LicenseAPI
    let defaults: UserDefaults

    /// Called whenever `state` changes (including the initial `initialize()` assignment).
    /// Production wires this up in App.swift to refresh Menubar, sync Sparkle cookie, and notify ProTransitionManager.
    /// Tests leave it unset to avoid side effects.
    var onStateChanged: ((LicenseState) -> Void)?

    /// Provides the current app version for version-limited variant checks. Defaults to the bundle's version;
    /// tests override to simulate upgrades across cutoffs.
    var currentAppVersion: () -> String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Invoked before a license activation flips `state` to `.pro` so any Pro selections that were
    /// snapshotted when Pro locked can be restored. Wired at app startup; no-op by default so tests
    /// can drive activation without side effects.
    var onBeforeProUnlock: () -> Void = { }

    private(set) var state: LicenseState = .trialExpired {
        didSet { onStateChanged?(state) }
    }

    var customerEmail: String? { defaults.string(forKey: Self.customerEmailKey) }

    var isLifetimeVariant: Bool { true }

    var isProAvailable: Bool { true }

    /// Pro features are locked out as soon as the license is no longer valid. Degradable Pro
    /// preferences are downgraded to their Free equivalents immediately via
    /// `ProTransitionManager.onProLockEngaged()`, wired to the state-change hook in App.swift.
    var isProLocked: Bool { false }

    var trialStartDate: Date? {
        guard defaults.object(forKey: "trialStartDate") != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: "trialStartDate"))
    }

    var daysSinceTrialStart: Int {
        guard let start = trialStartDate else { return 0 }
        return Int(clock.now.timeIntervalSince(start) / 86400)
    }

    init(clock: Clock, keychain: Keychain, api: LicenseAPI, defaults: UserDefaults) {
        self.clock = clock
        self.keychain = keychain
        self.api = api
        self.defaults = defaults
    }

    func initialize() {
        state = .pro
    }

    /// Trial `daysRemaining` is baked into the `state` enum, so it stays frozen until something
    /// reassigns `state`. Call this from UI surfaces before they read `state` so the day count
    /// reflects the current clock. `didSet` only fires when the value actually changed.
    func refreshState() {
        if state != .pro { state = .pro }
    }

    func activate(_ licenseKey: String, completion: @escaping (Result<Void, Error>) -> Void) {
        onBeforeProUnlock()
        state = .pro
        completion(.success(()))
    }

    func deactivate(completion: @escaping (Result<Void, Error>) -> Void) {
        state = .pro
        completion(.success(()))
    }

    /// Remote-deactivate a specific instance that isn't this machine — used to reclaim a seat
    /// before re-running activation. Does not touch local keychain/UserDefaults state.
    func deactivateInstance(licenseKey: String, instanceId: String, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.success(()))
    }

    func computeState() -> LicenseState {
        return .pro
    }

    private func computeTrialState() -> LicenseState {
        if defaults.object(forKey: "trialStartDate") == nil {
            defaults.set(clock.now.timeIntervalSince1970, forKey: "trialStartDate")
        }
        let trialStart = Date(timeIntervalSince1970: defaults.double(forKey: "trialStartDate"))
        let daysSinceTrialStart = Int(clock.now.timeIntervalSince(trialStart) / (24 * 60 * 60))
        guard daysSinceTrialStart < Self.trialDuration else { return .trialExpired }
        return .trial(daysRemaining: Self.trialDuration - daysSinceTrialStart)
    }

    func scheduleAsyncRevalidationIfNeeded() {}

    func revalidateWithServer() {}

    #if DEBUG
    func mockTrialUser() {
        keychain.remove(account: Self.keychainKeyAccount)
        keychain.remove(account: Self.keychainInstanceAccount)
        keychain.remove(account: Self.keychainVariantAccount)
        defaults.set(clock.now.timeIntervalSince1970, forKey: "trialStartDate")
        defaults.removeObject(forKey: "lastValidation")
        defaults.removeObject(forKey: "lastValidationResult")
        defaults.removeObject(forKey: Self.customerEmailKey)
        state = .trial(daysRemaining: Self.trialDuration)
    }

    func mockTrialExpired() {
        keychain.remove(account: Self.keychainKeyAccount)
        keychain.remove(account: Self.keychainInstanceAccount)
        keychain.remove(account: Self.keychainVariantAccount)
        defaults.removeObject(forKey: "trialStartDate")
        defaults.removeObject(forKey: "lastValidation")
        defaults.removeObject(forKey: "lastValidationResult")
        defaults.removeObject(forKey: Self.customerEmailKey)
        state = .trialExpired
    }

    func mockTrialDay(_ day: Int) {
        keychain.remove(account: Self.keychainKeyAccount)
        keychain.remove(account: Self.keychainInstanceAccount)
        keychain.remove(account: Self.keychainVariantAccount)
        let trialStart = clock.now.addingTimeInterval(-Double(day - 1) * 86400)
        defaults.set(trialStart.timeIntervalSince1970, forKey: "trialStartDate")
        defaults.removeObject(forKey: "lastValidation")
        defaults.removeObject(forKey: "lastValidationResult")
        defaults.removeObject(forKey: Self.customerEmailKey)
        let daysRemaining = Self.trialDuration - (day - 1)
        state = daysRemaining > 0 ? .trial(daysRemaining: daysRemaining) : .trialExpired
    }

    func mockProUser() {
        keychain.setValue("MOCK-PRO-LICENSE-KEY", account: Self.keychainKeyAccount)
        keychain.setValue("mock-instance-id", account: Self.keychainInstanceAccount)
        defaults.set(clock.now.timeIntervalSince1970, forKey: "lastValidation")
        defaults.set(true, forKey: "lastValidationResult")
        defaults.set("john@cool-software.com", forKey: Self.customerEmailKey)
        onBeforeProUnlock()
        state = .pro
    }
    #endif
}
