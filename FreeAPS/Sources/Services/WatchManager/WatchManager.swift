import Foundation
import SwiftDate
import Swinject
import WatchConnectivity
import CoreData

protocol WatchManager {}

final class BaseWatchManager: NSObject, WatchManager, Injectable {
    private let session: WCSession
    private var state = WatchState()
    private let processQueue = DispatchQueue(label: "BaseWatchManager.processQueue")

    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var apsManager: APSManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var carbsStorage: CarbsStorage!
    @Injected() private var tempTargetsStorage: TempTargetsStorage!
    @Injected() private var garmin: GarminManager!
    @Injected() private var nightscout: NightscoutManager!

    let coreDataStorage = CoreDataStorage()
    let coredataContext = CoreDataStack.shared.persistentContainer.viewContext

    private var lifetime = Lifetime()

    init(resolver: Resolver, session: WCSession = .default) {
        self.session = session
        super.init()
        injectServices(resolver)

        if WCSession.isSupported() {
            session.delegate = self
            session.activate()
        }

        broadcaster.register(GlucoseObserver.self, observer: self)
        broadcaster.register(SuggestionObserver.self, observer: self)
        broadcaster.register(SettingsObserver.self, observer: self)
        broadcaster.register(PumpHistoryObserver.self, observer: self)
        broadcaster.register(PumpSettingsObserver.self, observer: self)
        broadcaster.register(BasalProfileObserver.self, observer: self)
        broadcaster.register(TempTargetsObserver.self, observer: self)
        broadcaster.register(CarbsObserver.self, observer: self)
        broadcaster.register(EnactedSuggestionObserver.self, observer: self)
        broadcaster.register(PumpBatteryObserver.self, observer: self)
        broadcaster.register(PumpReservoirObserver.self, observer: self)
        garmin.stateRequet = { [weak self] () -> Data in
            guard let self = self, let data = try? JSONEncoder().encode(self.state) else {
                warning(.service, "Cannot encode watch state")
                return Data()
            }
            return data
        }

        configureState()
    }

    private func configureState() {
        processQueue.async {
            let overrideStorage = OverrideStorage()
            let readings = self.coreDataStorage.fetchGlucose(interval: DateFilter().twoHours)
            let glucoseValues = self.glucoseText(readings)
            self.state.glucose = glucoseValues.glucose
            self.state.trend = glucoseValues.trend
            self.state.delta = glucoseValues.delta
            self.state.trendRaw = self.convertTrendToDirectionText(trend: glucoseValues.trend)
            self.state.glucoseDate = readings.first?.date ?? .distantPast
            self.state.glucoseDateInterval = self.state.glucoseDate.map {
                guard $0.timeIntervalSince1970 > 0 else { return 0 }
                return UInt64($0.timeIntervalSince1970)
            }
            self.state.lastLoopDate = self.enactedSuggestion?.recieved == true ? self.enactedSuggestion?.deliverAt : self
                .apsManager.lastLoopDate
            self.state.lastLoopDateInterval = self.state.lastLoopDate.map {
                guard $0.timeIntervalSince1970 > 0 else { return 0 }
                return UInt64($0.timeIntervalSince1970)
            }
            self.state.bolusIncrement = self.settingsManager.preferences.bolusIncrement
            self.state.maxCOB = self.settingsManager.preferences.maxCOB
            self.state.maxBolus = self.settingsManager.pumpSettings.maxBolus
            self.state.carbsRequired = self.suggestion?.carbsReq

            var insulinRequired = self.suggestion?.insulinReq ?? 0

            var double: Decimal = 2
            if self.suggestion?.manualBolusErrorString == 0 {
                insulinRequired = self.suggestion?.insulinForManualBolus ?? 0
                double = 1
            }

            self.state.useNewCalc = self.settingsManager.settings.useCalc

            if !(self.state.useNewCalc ?? false) {
                self.state.bolusRecommended = self.apsManager
                    .roundBolus(amount: max(
                        insulinRequired * (self.settingsManager.settings.insulinReqPercentage / 100) * double,
                        0
                    ))
            } else {
                let recommended = self.newBolusCalc(delta: readings, suggestion: self.suggestion)
                self.state.bolusRecommended = self.apsManager
                    .roundBolus(amount: max(recommended, 0))
            }

            self.state.iob = self.suggestion?.iob
            self.state.cob = self.suggestion?.cob
            self.state.tempTargets = self.tempTargetsStorage.presets()
                .map { target -> TempTargetWatchPreset in
                    let untilDate = self.tempTargetsStorage.current().flatMap { currentTarget -> Date? in
                        guard currentTarget.id == target.id else { return nil }
                        let date = currentTarget.createdAt.addingTimeInterval(TimeInterval(currentTarget.duration * 60))
                        return date > Date() ? date : nil
                    }
                    return TempTargetWatchPreset(
                        name: target.displayName,
                        id: target.id,
                        description: self.descriptionForTarget(target),
                        until: untilDate
                    )
                }

            self.state.overrides = overrideStorage.fetchProfiles()
                .map { preset -> OverridePresets_ in
                    let untilDate = overrideStorage.fetchLatestOverride().first.flatMap { currentOverride -> Date? in
                        guard currentOverride.id == preset.id, currentOverride.enabled else { return nil }

                        let duration = Double(currentOverride.duration ?? 0)
                        let overrideDate: Date = currentOverride.date ?? Date.now

                        let date = duration == 0 ? Date.distantFuture : overrideDate.addingTimeInterval(duration * 60)
                        return date > Date.now ? date : nil
                    }

                    return OverridePresets_(
                        name: preset.name ?? "",
                        id: preset.id ?? "",
                        until: untilDate,
                        description: self.description(preset)
                    )
                }
            // Is there an active override but no preset?
            let currentButNoOverrideNotPreset = self.state.overrides.filter({ $0.until != nil }).first
            if let last = overrideStorage.fetchLatestOverride().first, last.enabled, currentButNoOverrideNotPreset == nil {
                let duration = Double(last.duration ?? 0)
                let overrideDate: Date = last.date ?? Date.now
                let date_ = duration == 0 ? Date.distantFuture : overrideDate.addingTimeInterval(duration * 60)
                let date = date_ > Date.now ? date_ : nil

                self.state.overrides
                    .append(OverridePresets_(name: "custom", id: last.id ?? "", until: date, description: self.description(last)))
            }

            self.state.bolusAfterCarbs = !self.settingsManager.settings.skipBolusScreenAfterCarbs
            self.state.displayOnWatch = self.settingsManager.settings.displayOnWatch
            self.state.displayFatAndProteinOnWatch = self.settingsManager.settings.displayFatAndProteinOnWatch
            self.state.confirmBolusFaster = self.settingsManager.settings.confirmBolusFaster
            self.state.profilesOrTempTargets = self.settingsManager.settings.profilesOrTempTargets

            let eBG = self.eventualBGString()
            self.state.eventualBG = eBG.map { "⇢ " + $0 }
            self.state.eventualBGRaw = eBG

            self.state.isf = self.suggestion?.isf

            let overrideArray = overrideStorage.fetchLatestOverride()

            if overrideArray.first?.enabled ?? false {
                let percentString = "\((overrideArray.first?.percentage ?? 100).formatted(.number)) %"
                self.state.override = percentString
            } else {
                self.state.override = "100 %"
            }

            self.sendState()
        }
    }

    private func sendState() {
        dispatchPrecondition(condition: .onQueue(processQueue))
        guard let data = try? JSONEncoder().encode(state) else {
            warning(.service, "Cannot encode watch state")
            return
        }

        garmin.sendState(data)

        guard session.isReachable else { return }
        session.sendMessageData(data, replyHandler: nil) { error in
            warning(.service, "Cannot send message to watch", error: error)
        }
    }

    private func glucoseText(_ glucose: [Readings]) -> (glucose: String, trend: String, delta: String) {
        let glucoseValue = glucose.first?.glucose ?? 0

        guard !glucose.isEmpty else { return ("--", "--", "--") }

        let delta = glucose.count >= 2 ? glucoseValue - glucose[1].glucose : nil

        let units = settingsManager.settings.units
        let glucoseText = glucoseFormatter
            .string(from: Double(
                units == .mmolL ? Decimal(glucoseValue).asMmolL : Decimal(glucoseValue)
            ) as NSNumber)!

        let directionText = glucose.first?.direction ?? "↔︎"
        let deltaText = delta
            .map {
                self.deltaFormatter
                    .string(from: Double(
                        units == .mmolL ? Decimal($0).asMmolL : Decimal($0)
                    ) as NSNumber)!
            } ?? "--"

        return (glucoseText, directionText, deltaText)
    }

    private func descriptionForTarget(_ target: TempTarget) -> String {
        let units = settingsManager.settings.units

        var low = target.targetBottom
        var high = target.targetTop
        if units == .mmolL {
            low = low?.asMmolL
            high = high?.asMmolL
        }

        let duration = targetFormatter.string(from: target.duration as NSNumber)!
        if let low = low {
            if low > 0 {
                return "Target \(targetFormatter.string(from: low as NSNumber)!)," + " \(duration) minute duration"
            }
        }

        return "Target unchanged, \(duration) minute duration"
    }

    private func eventualBGString() -> String? {
        guard let eventualBG = suggestion?.eventualBG else {
            return nil
        }
        let units = settingsManager.settings.units
        return eventualFormatter.string(
            from: (units == .mmolL ? eventualBG.asMmolL : Decimal(eventualBG)) as NSNumber
        )!
    }

    private func convertTrendToDirectionText(trend: String) -> String {
        switch trend {
        case "↑↑↑":
            return Direction.tripleUp.rawValue
        case "↑↑":
            return Direction.doubleUp.rawValue
        case "↑":
            return Direction.singleUp.rawValue
        case "↗︎":
            return Direction.fortyFiveUp.rawValue
        case "→":
            return Direction.flat.rawValue
        case "↘︎":
            return Direction.fortyFiveDown.rawValue
        case "↓":
            return Direction.singleDown.rawValue
        case "↓↓↓":
            return Direction.tripleDown.rawValue
        case "↓↓":
            return Direction.doubleDown.rawValue
        default:
            return Direction.notComputable.rawValue
        }
    }

    private func newBolusCalc(delta: [Readings], suggestion _: Suggestion?) -> Decimal {
        var conversion: Decimal = 1
        // Settings
        if settingsManager.settings.units == .mmolL {
            conversion = 0.0555
        }
        let isf = state.isf ?? 0
        let target = suggestion?.current_target ?? 0
        let carbratio = suggestion?.carbRatio ?? 0
        let bg = delta.first?.glucose ?? 0
        let cob = state.cob ?? 0
        let iob = state.iob ?? 0
        let useFattyMealCorrectionFactor = settingsManager.settings.fattyMeals
        let fattyMealFactor = settingsManager.settings.fattyMealFactor
        let maxBolus = settingsManager.pumpSettings.maxBolus
        var insulinCalculated: Decimal = 0
        // insulin needed for the current blood glucose
        let targetDifference = (Decimal(bg) - target) * conversion
        let targetDifferenceInsulin = targetDifference / isf
        // more or less insulin because of bg trend in the last 15 minutes
        var bgDelta: Int = 0
        if delta.count >= 3 {
            bgDelta = Int((delta.first?.glucose ?? 0) - delta[2].glucose)
        }
        let fifteenMinInsulin = (Decimal(bgDelta) * conversion) / isf
        // determine whole COB for which we want to dose insulin for and then determine insulin for wholeCOB
        let wholeCobInsulin = cob / carbratio
        // determine how much the calculator reduces/ increases the bolus because of IOB
        let iobInsulinReduction = (-1) * iob
        // adding everything together
        // add a calc for the case that no fifteenMinInsulin is available
        var wholeCalc: Decimal = 0
        if bgDelta != 0 {
            wholeCalc = (targetDifferenceInsulin + iobInsulinReduction + wholeCobInsulin + fifteenMinInsulin)
        } else {
            // add (rare) case that no glucose value is available -> maybe display warning?
            // if no bg is available, ?? sets its value to 0
            if bg == 0 {
                wholeCalc = (iobInsulinReduction + wholeCobInsulin)
            } else {
                wholeCalc = (targetDifferenceInsulin + iobInsulinReduction + wholeCobInsulin)
            }
        }
        // apply custom factor at the end of the calculations
        let result = wholeCalc * settingsManager.settings.overrideFactor
        // apply custom factor if fatty meal toggle in bolus calc config settings is on and the box for fatty meals is checked (in RootView)
        if useFattyMealCorrectionFactor {
            insulinCalculated = result * fattyMealFactor
        } else {
            insulinCalculated = result
        }
        // Not 0 or over maxBolus
        insulinCalculated = max(min(insulinCalculated, maxBolus), 0)
        return insulinCalculated
    }

    private func description(_ preset: OverridePresets) -> String {
        let rawtarget = (preset.target ?? 0) as Decimal

        let targetValue = settingsManager.settings.units == .mmolL ? rawtarget.asMmolL : rawtarget
        let target: String = rawtarget > 6 ? glucoseFormatter.string(from: targetValue as NSNumber) ?? "" : ""

        let percentage = preset.percentage != 100 ? preset.percentage.formatted() + "%" : ""
        let string = (preset.target ?? 0) as Decimal > 6 && !percentage.isEmpty ? target + " " + settingsManager.settings.units
            .rawValue + ", " + percentage : target + percentage
        return string
    }

    private func description(_ override: Override) -> String {
        let rawtarget = (override.target ?? 0) as Decimal

        let targetValue = settingsManager.settings.units == .mmolL ? rawtarget.asMmolL : rawtarget
        let target: String = rawtarget > 6 ? glucoseFormatter.string(from: targetValue as NSNumber) ?? "" : ""

        let percentage = override.percentage != 100 ? override.percentage.formatted() + "%" : ""
        let string = (override.target ?? 0) as Decimal > 6 && !percentage.isEmpty ? target + " " + settingsManager.settings.units
            .rawValue + ", " + percentage : target + percentage
        return string
    }

    private var glucoseFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        if settingsManager.settings.units == .mmolL {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
        }
        formatter.roundingMode = .halfUp
        return formatter
    }

    private var eventualFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+"
        return formatter
    }

    private var targetFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var suggestion: Suggestion? {
        storage.retrieve(OpenAPS.Enact.suggested, as: Suggestion.self)
    }

    private var enactedSuggestion: Suggestion? {
        storage.retrieve(OpenAPS.Enact.enacted, as: Suggestion.self)
    }
}

extension BaseWatchManager: WCSessionDelegate {
    func sessionDidBecomeInactive(_: WCSession) {}

    func sessionDidDeactivate(_: WCSession) {}

    func session(_: WCSession, activationDidCompleteWith state: WCSessionActivationState, error _: Error?) {
        debug(.service, "WCSession is activated: \(state == .activated)")
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        debug(.service, "WCSession got message: \(message)")

        if let stateRequest = message["stateRequest"] as? Bool, stateRequest {
            processQueue.async {
                self.sendState()
            }
        }
    }

    func session(_: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        debug(.service, "WCSession got message with reply handler: \(message)")

        if let carbs = message["carbs"] as? Double,
           let fat = message["fat"] as? Double,
           let protein = message["protein"] as? Double,
           carbs > 0 || fat > 0 || protein > 0
        {
            carbsStorage.storeCarbs(
                [CarbsEntry(
                    id: UUID().uuidString,
                    createdAt: Date(),
                    actualDate: nil,
                    carbs: Decimal(carbs),
                    fat: Decimal(fat),
                    protein: Decimal(protein), note: nil,
                    enteredBy: CarbsEntry.manual,
                    isFPU: false, fpuID: nil
                )]
            )

            if settingsManager.settings.skipBolusScreenAfterCarbs {
                apsManager.determineBasalSync()
                replyHandler(["confirmation": true])
                return
            } else {
                apsManager.determineBasal()
                    .sink { _ in
                        replyHandler(["confirmation": true])
                    }
                    .store(in: &lifetime)
                return
            }
        }

        if let tempTargetID = message["tempTarget"] as? String {
            if var preset = tempTargetsStorage.presets().first(where: { $0.id == tempTargetID }) {
                preset.createdAt = Date()
                tempTargetsStorage.storeTempTargets([preset])

                // Update carb profile settings based on the preset values
                settingsManager.setLowCarbProfileEnabled(preset.lowCarbProfile ?? true)
                settingsManager.setMediumCarbProfileEnabled(preset.mediumCarbProfile ?? false)
                settingsManager.setHighCarbProfileEnabled(preset.highCarbProfile ?? false)
                
                coredataContext.performAndWait {
                    var tempTargetsArray = [TempTargets]()
                    let requestTempTargets = TempTargets.fetchRequest() as NSFetchRequest<TempTargets>
                    let sortTT = NSSortDescriptor(key: "date", ascending: false)
                    requestTempTargets.sortDescriptors = [sortTT]
                    try? tempTargetsArray = coredataContext.fetch(requestTempTargets)
                    
                    let whichID = tempTargetsArray.first(where: { $0.id == tempTargetID })

                    if tempTargetID != nil {
                        let saveToCoreData = TempTargets(context: self.coredataContext)
                        saveToCoreData.active = true
                        saveToCoreData.date = Date()
                        saveToCoreData.startDate = Date()
                        saveToCoreData.lowCarbProfile = preset.lowCarbProfile ?? true
                        saveToCoreData.mediumCarbProfile = preset.mediumCarbProfile ?? false
                        saveToCoreData.highCarbProfile = preset.highCarbProfile ?? false

                        try? self.coredataContext.save()
                    }
                }

                replyHandler(["confirmation": true])
                return
            } else if tempTargetID == "cancel" {
                let entry = TempTarget(
                    name: TempTarget.cancel,
                    createdAt: Date(),
                    targetTop: 0,
                    targetBottom: 0,
                    duration: 0,
                    enteredBy: TempTarget.manual,
                    reason: TempTarget.cancel,
                    lowCarbProfile: true,
                    mediumCarbProfile: false,
                    highCarbProfile: false
                )
                settingsManager.setLowCarbProfileEnabled(true)
                tempTargetsStorage.storeTempTargets([entry])
                replyHandler(["confirmation": true])
                return
            }
        }

        if let overrideID = message["override"] as? String {
            let storage = OverrideStorage()
            if let preset = storage.fetchProfiles().first(where: { $0.id == overrideID }) {
                preset.date = Date.now

                // Cancel eventual current active override first
                if let activeOveride = storage.fetchLatestOverride().first, activeOveride.enabled {
                    let name = storage.isPresetName()

                    if let duration = storage.cancelProfile() {
                        let presetName = preset.name
                        let nsString = name != nil ? name! : activeOveride.percentage.formatted()
                        nightscout.editOverride(nsString, duration, activeOveride.date ?? Date())
                    }
                }
                // Activate the new override and uplad the new ovderride to NS. Some duplicate code now.
                storage.overrideFromPreset(preset)
                nightscout.uploadOverride(
                    preset.name ?? "",
                    Double(preset.duration ?? 0),
                    storage.fetchLatestOverride().first?.date ?? Date.now
                )
                replyHandler(["confirmation": true])
                configureState()
                return
            } else if overrideID == "cancel" {
                if let activeOveride = storage.fetchLatestOverride().first, activeOveride.enabled {
                    let presetName = storage.isPresetName()
                    let nsString = presetName != nil ? presetName : activeOveride.percentage.formatted()

                    if let duration = storage.cancelProfile() {
                        nightscout.editOverride(nsString!, duration, activeOveride.date ?? Date.now)
                        replyHandler(["confirmation": true])
                        configureState()
                    }
                }
                return
            }
        }

        if let bolus = message["bolus"] as? Double, bolus > 0 {
            apsManager.enactBolus(amount: bolus, isSMB: false)
            replyHandler(["confirmation": true])
            return
        }

        replyHandler(["confirmation": false])
    }

    func session(_: WCSession, didReceiveMessageData _: Data) {}

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            processQueue.async {
                self.sendState()
            }
        }
    }
}

extension BaseWatchManager:
    GlucoseObserver,
    SuggestionObserver,
    SettingsObserver,
    PumpHistoryObserver,
    PumpSettingsObserver,
    BasalProfileObserver,
    TempTargetsObserver,
    CarbsObserver,
    EnactedSuggestionObserver,
    PumpBatteryObserver,
    PumpReservoirObserver
{
    func glucoseDidUpdate(_: [BloodGlucose]) {
        configureState()
    }

    func suggestionDidUpdate(_: Suggestion) {
        configureState()
    }

    func settingsDidChange(_: FreeAPSSettings) {
        configureState()
    }

    func pumpHistoryDidUpdate(_: [PumpHistoryEvent]) {
        // TODO:
    }

    func pumpSettingsDidChange(_: PumpSettings) {
        configureState()
    }

    func basalProfileDidChange(_: [BasalProfileEntry]) {
        // TODO:
    }

    func tempTargetsDidUpdate(_: [TempTarget]) {
        configureState()
    }

    func carbsDidUpdate(_: [CarbsEntry]) {
        // TODO:
    }

    func enactedSuggestionDidUpdate(_: Suggestion) {
        configureState()
    }

    func pumpBatteryDidChange(_: Battery) {
        // TODO:
    }

    func pumpReservoirDidChange(_: Decimal) {
        // TODO:
    }
}
