import HealthKit
import SwiftDate
import SwiftUI

struct MainView: View {
    private enum Config {
        static let lag: TimeInterval = 30
    }

    @EnvironmentObject var state: WatchStateModel

    @State var isCarbsActive = false
    @State var isTargetsActive = false
    @State var isBolusActive = false
    @State private var pulse = 0
    @State private var steps = 0
    @State private var scale: CGFloat = 1.0

    @GestureState var isDetectingLongPress = false
    @State var completedLongPress = false

    @State var completedLongPressOfBG = false
    @GestureState var isDetectingLongPressOfBG = false

    private var healthStore = HKHealthStore()
    let heartRateQuantity = HKUnit(from: "count/min")

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                Color.bgDarkBlue,
                Color.bgDarkerDarkBlue,
                Color.bgDarkBlue
            ]),
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !completedLongPressOfBG {
                if state.timerDate.timeIntervalSince(state.lastUpdate) > 10 {
                    HStack {
                        Text("").fontWeight(.semibold).font(.caption2)
                    }
                }
            }

            VStack {
                if !completedLongPressOfBG {
                    header
                    Spacer()
                    buttons
                } else {
                    bigHeader
                }
            }

            if state.isConfirmationViewActive {
                ConfirmationView(success: $state.confirmationSuccess)
                    .background(backgroundGradient)
            }

            if state.isConfirmationBolusViewActive {
                BolusConfirmationView()
                    .environmentObject(state)
                    .background(backgroundGradient)
            }
        }
        .frame(maxHeight: .infinity)
        .padding()
        .onReceive(state.timer) { date in
            state.timerDate = date
            state.requestState()
        }
        .background(backgroundGradient)
        .edgesIgnoringSafeArea(.all)
        .onAppear {
            state.requestState()
        }
        .overlay(
            loopTime
                .offset(x: 0, y: -3)
        )
    }

    var glucoseView: some View {
        CurrentGlucoseView(
        )
    }

    var isf: some View {
        Group {
            switch state.displayOnWatch {
            case .HR:
                HStack {
                    if completedLongPress {
                        Text("❤️ \(pulse)")
                            .fontWeight(.regular)
                            .font(.custom("activated", size: 20))
                            .scaledToFill()
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.5)
                            .scaleEffect(isDetectingLongPress ? 3 : 1)
                            .gesture(longPress)
                    } else {
                        Text("❤️ \(pulse)")
                            .fontWeight(.regular)
                            .font(.caption2)
                            .scaledToFill()
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.5)
                            .scaleEffect(isDetectingLongPress ? 3 : 1)
                            .gesture(longPress)
                    }
                }
            case .BGTarget:
                if let eventualBG = state.eventualBG.nonEmpty {
                    Text(eventualBG)
                        .font(.caption2)
                        .scaledToFill()
                        .foregroundColor(.secondary)
                        .minimumScaleFactor(0.5)
                } else {
                    EmptyView()
                }
            case .steps:
                Text("🦶 \(steps)")
                    .fontWeight(.regular)
                    .font(.caption2)
                    .scaledToFill()
                    .foregroundColor(.white)
                    .minimumScaleFactor(0.5)
            case .isf:
                let isfValue: String = state.isf != nil ? "\(state.isf ?? 0)" : "-"
                HStack(alignment: .lastTextBaseline) {
                    Text(isfValue)
                        .fontWeight(.semibold)
                        .font(.caption2)
                        .frame(width: 60, alignment: .trailing)
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                    Image(systemName: "arrow.up.arrow.down")
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 13, height: 13)
                        .foregroundColor(.white)
                        .offset(x: 1, y: 2)
                }
            }
        }
    }

    var cob: some View {
        HStack(alignment: .firstTextBaseline) {
            Image("premeal")
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundColor(.loopYellow)
                .offset(x: 1, y: 1)
            Text(iobFormatter.string(from: (state.cob ?? 0) as NSNumber)!)
                .fontWeight(.semibold)
                .font(.caption2)
                .frame(width: 60, alignment: .leading)
                .foregroundColor(Color.white)
                .minimumScaleFactor(0.5)
        }
    }

    var iob: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "drop.circle")
                .renderingMode(.template)
                .resizable()
                .frame(width: 14, height: 14)
                .foregroundColor(.insulin)
                .offset(x: 1, y: 2)
            Text(iobFormatter.string(from: (state.iob ?? 0) as NSNumber)!)
                .fontWeight(.semibold)
                .font(.caption2)
                .frame(width: 60, alignment: .leading)
                .foregroundColor(Color.white)
                .minimumScaleFactor(0.5)
        }
    }

    var blinkyView: some View {
        ZStack {
            if !completedLongPressOfBG {
                if state.timerDate.timeIntervalSince(state.lastUpdate) > 10 {
                    PulsatingCircleView(color: color, size: 11.5)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 11.5, height: 11.5)
                        .scaleEffect(1)
                }
            }
        }
    }


    var loopTime: some View {
        VStack {
            if state.lastLoopDate != nil {
                let minutesPassed = Int(timeString) ?? 0
                if minutesPassed > 5 {
                    Text(timeString).fontWeight(.semibold).font(.caption2)
                } else {
                    Text("").fontWeight(.semibold).font(.caption2)
                }
            } else {
                Text("--").fontWeight(.semibold).font(.caption2)
            }
        }
    }

    var header: some View {
        VStack {
            HStack(alignment: .top) {}
            Spacer()
            Spacer()
                .onAppear(perform: start)
                .overlay(
                    glucoseView
                        .scaleEffect(0.75) // Adjust the scaling factor as needed
                        .offset(x: 0, y: -5), // Start with centered, adjust as needed
                    alignment: .center // Ensures that the overlay is centered in the VStack
                )
                /* .overlay(
                     Circle()
                         .fill(color)
                         .frame(width: 11, height: 11)
                         .scaleEffect(1)
                         .offset(x: 0, y: -37),
                     alignment: .center
                 ) */
                .overlay(
                    blinkyView
                        .scaleEffect(1)
                        .offset(x: 0, y: -37),
                    alignment: .center
                )
                .overlay(
                    isf
                        .scaleEffect(1)
                        .offset(x: 36, y: 49),
                    alignment: .center
                )
                .overlay(
                    cob
                        .scaleEffect(1)
                        .offset(x: -36, y: -59),
                    alignment: .center
                )
                .overlay(
                    iob
                        .scaleEffect(1)
                        .offset(x: -40, y: 49),
                    alignment: .center
                )
        }
        .gesture(longPresBGs)
    }

    var bigHeader: some View {
        VStack(alignment: .center) {
            HStack {
                Text(state.glucose).font(.custom("Big BG", size: 55))
                    .minimumScaleFactor(1) // Allows the text size to adjust to fit the space
                    .lineLimit(1) // Ensures the text does not wrap
                    .frame(minWidth: 0, maxWidth: .infinity) // Adjust maxWidth as needed
                Text(state.trend != "→" ? state.trend : "")
                    .scaledToFill()
                    .minimumScaleFactor(0.5)
            }.padding(.bottom, 35)
        }
        .gesture(longPresBGs)
    }

    var longPress: some Gesture {
        LongPressGesture(minimumDuration: 1)
            .updating($isDetectingLongPress) { currentState, gestureState,
                _ in
                gestureState = currentState
            }
            .onEnded { _ in
                if completedLongPress {
                    completedLongPress = false
                } else { completedLongPress = true }
            }
    }

    var longPresBGs: some Gesture {
        LongPressGesture(minimumDuration: 1)
            .updating($isDetectingLongPressOfBG) { currentState, gestureState,
                _ in
                gestureState = currentState
            }
            .onEnded { _ in
                if completedLongPressOfBG {
                    completedLongPressOfBG = false
                } else { completedLongPressOfBG = true }
            }
    }

    var carbs: some View {
        NavigationLink(isActive: $state.isCarbsViewActive) {
            CarbsView()
                .environmentObject(state)
        } label: {
            Image("carbs1", bundle: nil)
                .renderingMode(.template)
                .resizable()
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
        }
    }

    var target: some View {
        HStack {
            if state.profilesOrTempTargets {
                NavigationLink(isActive: $state.isTempTargetViewActive) {
                    TempTargetsView()
                        .environmentObject(state)
                } label: {
                        Image("target1", bundle: nil)
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 32, height: 32)
                            .foregroundColor(.white)
                }
            }
        }
    }
    
    var targetTimeRemaining: some View {
        HStack {
            if state.profilesOrTempTargets {
                NavigationLink(isActive: $state.isTempTargetViewActive) {
                    TempTargetsView()
                        .environmentObject(state)
                } label: {
                        if let until = state.tempTargets.compactMap(\.until).first, until > Date() {
                            Text(until, style: .timer)
                                .scaledToFill()
                                .font(.system(size: 12))
                                /*.fontWeight(.regular)
                                .font(.caption2)
                                .scaledToFill()
                                .foregroundColor(.white)
                                .minimumScaleFactor(0.375)*/
                    }
                }
            }
        }
    }


    var bolus: some View {
        NavigationLink(isActive: $state.isBolusViewActive) {
            BolusView()
                .environmentObject(state)
        } label: {
            Image("bolus", bundle: nil)
                .renderingMode(.template)
                .resizable()
                .frame(width: 32, height: 32)
                .foregroundColor(.white)
        }
    }

    var buttons: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                    .fill(Color("Color"))
                    .frame(height: geometry.size.height / 1.875)
                    .cornerRadius(15)
                    .shadow(color: Color.black.opacity(0.75), radius: 5)
                    .padding([.leading, .trailing], 3.25)
            }
            .overlay(
                carbs
                    .scaleEffect(1)
                    .offset(x: -42.5, y: 0),
                alignment: .center
            )
            .overlay(
                targetTimeRemaining
                    .scaleEffect(1)
                    .offset(x: 1.5, y: -29),
                alignment: .center
            )
            .overlay(
                target
                    .scaleEffect(1)
                    .offset(x: 1.5, y: 0),
                alignment: .center
            )
            .overlay(
                bolus
                    .scaleEffect(1)
                    .offset(x: 42.5, y: 0),
                alignment: .center
            )
            .buttonStyle(PlainButtonStyle())
            .frame(height: geometry.size.height)
            .scaleEffect(1.0625)
            .offset(x: 0, y: 20)
        }
    }

    func start() {
        autorizeHealthKit()
        startHeartRateQuery(quantityTypeIdentifier: .heartRate)
        startStepsQuery(quantityTypeIdentifier: .stepCount)
    }

    func autorizeHealthKit() {
        let healthKitTypes: Set = [
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.stepCount)!,
            HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier.heartRate)!
        ]
        healthStore.requestAuthorization(toShare: healthKitTypes, read: healthKitTypes) { _, _ in }
    }

    private func startStepsQuery(quantityTypeIdentifier _: HKQuantityTypeIdentifier) {
        let type = HKQuantityType.quantityType(forIdentifier: .stepCount)!
        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)
        var interval = DateComponents()
        interval.day = 1
        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: nil,
            options: [.cumulativeSum],
            anchorDate: startOfDay,
            intervalComponents: interval
        )

        query.initialResultsHandler = { _, result, _ in
            var resultCount = 0.0
            guard let result = result else {
                self.steps = 0
                return
            }
            result.enumerateStatistics(from: startOfDay, to: now) { statistics, _ in

                if let sum = statistics.sumQuantity() {
                    // Get steps (they are of double type)
                    resultCount = sum.doubleValue(for: HKUnit.count())
                } // end if
                // Return
                self.steps = Int(resultCount)
            }
        }

        query.statisticsUpdateHandler = {
            _, statistics, _, _ in

            // If new statistics are available
            if let sum = statistics?.sumQuantity() {
                let resultCount = sum.doubleValue(for: HKUnit.count())
                // Return
                self.steps = Int(resultCount)
            } // end if
        }
        healthStore.execute(query)
    }

    private func startHeartRateQuery(quantityTypeIdentifier: HKQuantityTypeIdentifier) {
        let devicePredicate = HKQuery.predicateForObjects(from: [HKDevice.local()])
        let updateHandler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
            _, samples, _, _, _ in
            guard let samples = samples as? [HKQuantitySample] else {
                return
            }
            self.process(samples, type: quantityTypeIdentifier)
        }
        let query = HKAnchoredObjectQuery(
            type: HKObjectType.quantityType(forIdentifier: quantityTypeIdentifier)!,
            predicate: devicePredicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit,
            resultsHandler: updateHandler
        )
        query.updateHandler = updateHandler
        healthStore.execute(query)
    }

    private func process(_ samples: [HKQuantitySample], type: HKQuantityTypeIdentifier) {
        var lastHeartRate = 0.0
        for sample in samples {
            if type == .heartRate {
                lastHeartRate = sample.quantity.doubleValue(for: heartRateQuantity)
            }
            pulse = Int(lastHeartRate)
        }
    }

    private var iobFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        return formatter
    }

    private var timeString: String {
        let minAgo = Int((Date().timeIntervalSince(state.lastLoopDate ?? .distantPast) - Config.lag) / 60) + 1
        if minAgo > 1440 {
            return "--"
        }
        return "\(minAgo) " + NSLocalizedString("min", comment: "Minutes ago since last loop")
    }

    private var color: Color {
        guard let lastLoopDate = state.lastLoopDate else {
            return .loopGray
        }
        let delta = Date().timeIntervalSince(lastLoopDate) - Config.lag

        if delta <= 5.minutes.timeInterval {
            return .loopGreen
        } else if delta <= 10.minutes.timeInterval {
            return .loopYellow
        } else {
            return .loopRed
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        let state = WatchStateModel()

        state.glucose = "15,8"
        state.delta = "+888"
        state.iob = 100.38
        state.cob = 112.123
        state.lastLoopDate = Date().addingTimeInterval(-200)
        state
            .tempTargets =
            [TempTargetWatchPreset(name: "Test", id: "test", description: "", until: Date().addingTimeInterval(3600 * 3))]

        return Group {
            MainView()
            MainView().previewDevice("Apple Watch Series 5 - 40mm")
            MainView().previewDevice("Apple Watch Series 3 - 38mm")
        }.environmentObject(state)
    }
}

struct PulsatingCircleView: View {
    var color: Color
    var size: CGFloat = 20.0
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(animate ? 1.2 : 0.6)
            .animation(
                Animation.easeInOut(duration: 1).repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear {
                self.animate = true
            }
    }
}
