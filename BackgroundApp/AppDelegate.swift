import Cocoa
import Foundation
import CoreLocation
import SunCalc

class AppDelegate: NSObject, NSApplicationDelegate {

    enum TimeOfDay {
        case morning
        case day
        case evening
        case night

        // Total mapping enforced by the compiler
        var assetID: String {
            switch self {
            case .morning: return "B2FC91ED-6891-4DEB-85A1-268B2B4160B6"
            case .day:     return "4C108785-A7BA-422E-9C79-B0129F1D5550"
            case .evening: return "52ACB9B8-75FC-4516-BC60-4550CFF3B661"
            case .night:   return "CF6347E2-4F81-4410-8892-4830991B6C5A"
            }
        }
    }
    
    // MARK: - Paths
    // Use URL-based paths for safety and correctness
    private let indexURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeURL: URL = appSupport.appendingPathComponent("com.apple.wallpaper/Store", isDirectory: true)
        return storeURL.appendingPathComponent("Index.plist", isDirectory: false)
    }()

    // MARK: - Status Bar
    private var statusItem: NSStatusItem?
    private let statusMenu = NSMenu()

    // MARK: - Location & Scheduling
    private let locationManager = CLLocationManager()
    private var lastLocation: CLLocation?
    private var morningTimer: Timer?
    private var eveningTimer: Timer?
    private var midnightTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar UI
        setupStatusBar()

        // Observe system theme changes (keep existing behavior)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(interfaceModeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        // Observe wake to reconcile missed transitions and reschedule
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // Location manager setup
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 5000 // 5 km

        // Request permission (also available via status bar menu)
        requestLocationAuthorization()

        // If already authorized at launch, proactively request a location now
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
            locationManager.startMonitoringSignificantLocationChanges()
        default:
            break
        }

        // If we already have a location (e.g., from earlier in the session), schedule immediately
        if let loc = lastLocation {
            scheduleGoldenHourEvents(for: loc.coordinate, on: Date())
        }

        // Schedule daily reschedule shortly after midnight
        scheduleMidnightReschedule()

        print("App launched and running in background...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        invalidateTimers()
    }

    // MARK: - Status Bar Setup
    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Wallpaper Scheduler")
        }

        let requestItem = NSMenuItem(title: "Request Location Access", action: #selector(requestLocationFromMenu), keyEquivalent: "")
        requestItem.target = self

        let refreshItem = NSMenuItem(title: "Refresh Schedule", action: #selector(refreshScheduleFromMenu), keyEquivalent: "r")
        refreshItem.target = self

        statusMenu.addItem(requestItem)
        statusMenu.addItem(refreshItem)
        statusMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem?.menu = statusMenu
    }

    @objc private func requestLocationFromMenu() {
        requestLocationAuthorization(promptIfNeeded: true)
    }

    @objc private func refreshScheduleFromMenu() {
        if let loc = lastLocation {
            scheduleGoldenHourEvents(for: loc.coordinate, on: Date())
        } else {
            locationManager.requestLocation()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Theme (existing)
    @objc func interfaceModeChanged() {
        let isDarkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        print("Theme changed to: \(isDarkMode ? "Dark" : "Light")")

        switchTo(timeOfDay: isDarkMode ? .night : .day)
    }

    // MARK: - Wake handling and reconciliation
    @objc private func systemDidWake() {
        print("System did wake")
        guard let loc = lastLocation else {
            // Try to get a fresh location and schedule once we have it
            locationManager.requestLocation()
            return
        }

        // Recompute today's times
        let times = SunCalc.getTimes(date: Date(), latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)

        // reconcile missed transitions: if now is past morning or evening golden hour starts,
        // switch immediately to the appropriate state.
        reconcileCurrentTimeAgainst(times: times)

        // Reschedule timers for today
        scheduleGoldenHourEvents(for: loc.coordinate, on: Date())
    }

    private func reconcileCurrentTimeAgainst(times: SunCalc) {
        let now = Date()

        // We only care about nightEnd (morning start) and goldenHour (evening start).
        guard let morningStart = times.nightEnd else {
            print("No night end time available to reconcile.")
            return
        }

        // goldenHour is the evening golden hour start in SunCalc
        guard let eveningStart = times.goldenHour else {
            print("No evening golden hour time available to reconcile.")
            return
        }

        // Only reconcile if day or night transition has not yet occurred
        let isDarkMode = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        if now >= morningStart && now < eveningStart && isDarkMode {
            // Past morning start but before day → ensure morning is active
            print("Reconcile on wake: now past morning start, switching to morning.")
            switchTo(timeOfDay: .morning)
        } else if now >= eveningStart && !isDarkMode {
            // Past evening start but before night → ensure evening is active
            print("Reconcile on wake: now past evening start, switching to evening.")
            switchTo(timeOfDay: .evening)
        } else {
            // Before morning start → remain in night until morning timer fires
            // After day start → remain in day until evening timer fires
            print("Reconcile on wake: now in day or night.")
        }
    }

    // MARK: - Wallpaper switching helpers
    private func switchTo(timeOfDay: TimeOfDay) {
        let assetID = timeOfDay.assetID

        do {
            try updateIndexPlist(withAssetID: assetID)
            refreshWallpaper()
            print("Updated Index.plist with assetID \(assetID) for \(timeOfDay)")
        } catch {
            print("Failed to update Index.plist: \(error)")
        }
    }

    // Safely update Index.plist in place
    private func updateIndexPlist(withAssetID assetID: String) throws {
        // Read existing plist
        let data = try Data(contentsOf: indexURL)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var root = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: &format) as? [String: Any] else {
            throw NSError(domain: "WallpaperScheduler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Index.plist root is not a dictionary"])
        }

        // build configuration
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)

        // Helper to set nested path
        func setConfiguration(atTopKey topKey: String) {
            guard var top = root[topKey] as? [String: Any],
                  var linked = top["Linked"] as? [String: Any],
                  var content = linked["Content"] as? [String: Any],
                  var choices = content["Choices"] as? [Any],
                  !choices.isEmpty,
                  var choice = choices[0] as? [String: Any]
            else {
                print("Path \(topKey).Linked.Content.Choices.0 not found or wrong types")
                return
            }

            // Set Configuration
            choice["Configuration"] = configuration

            // Write back nested mutations
            choices[0] = choice
            content["Choices"] = choices
            linked["Content"] = content
            top["Linked"] = linked
            root[topKey] = top
        }

        setConfiguration(atTopKey: "AllSpacesAndDisplays")
        setConfiguration(atTopKey: "SystemDefault")

        // Write back using the original format if possible
        let outData = try PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        try outData.write(to: indexURL, options: .atomic)
    }

    func refreshWallpaper() {
        let process = Process()
        process.launchPath = "/usr/bin/killall"
        process.arguments = ["WallpaperAgent"]
        process.launch()
        process.waitUntilExit()
    }

    // MARK: - Location Authorization & Updates
    private func requestLocationAuthorization(promptIfNeeded: Bool = false) {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            // Only call this when you can present UI (e.g., via menu or at launch with status bar visible)
            if promptIfNeeded || NSApp.isActive || statusItem != nil {
                locationManager.requestWhenInUseAuthorization()
            }
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
            locationManager.startMonitoringSignificantLocationChanges()
        case .restricted, .denied:
            print("Location permission denied or restricted. Golden hour scheduling disabled.")
        @unknown default:
            break
        }
    }

    private func handleNewLocation(_ location: CLLocation) {
        // Debounce small movements
        if let last = lastLocation, last.distance(from: location) < 1000 {
            return
        }
        lastLocation = location
        scheduleGoldenHourEvents(for: location.coordinate, on: Date())
    }

    // MARK: - Scheduling using SunCalc (Golden Hours)
    // Night → Morning at nightEnd (start of morning golden hour)
    // Day → Evening at goldenHour (start of evening golden hour)
    private func scheduleGoldenHourEvents(for coordinate: CLLocationCoordinate2D, on date: Date) {
        // Cancel existing timers
        morningTimer?.invalidate()
        eveningTimer?.invalidate()

        let tz = TimeZone.current

        // SunCalc expects Date and coordinates; we’ll compute for "today" in local time
        let today = date

        // getTimes returns a non-optional SunCalc instance
        let times = SunCalc.getTimes(date: today, latitude: coordinate.latitude, longitude: coordinate.longitude)

        // We need nightEnd and goldenHour from the SunCalc instance; those are optionals.
        guard let morningGoldenHourStart = times.nightEnd,
              let eveningGoldenHourStart = times.goldenHour else {
            print("Golden hour times unavailable for today at \(coordinate)")
            return
        }

        // If a time is already in the past, it won't fire today; midnight reschedule will handle tomorrow.
        scheduleNamedTimer(name: "Night→Morning", at: morningGoldenHourStart) { [weak self] in
            self?.switchTo(timeOfDay: .morning)
        }

        scheduleNamedTimer(name: "Day→Evening", at: eveningGoldenHourStart) { [weak self] in
            self?.switchTo(timeOfDay: .evening)
        }

        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        formatter.timeZone = tz
        print("Scheduled Night→Morning at \(formatter.string(from: morningGoldenHourStart))")
        print("Scheduled Day→Evening at \(formatter.string(from: eveningGoldenHourStart))")
    }

    private func scheduleNamedTimer(name: String, at fireDate: Date, handler: @escaping () -> Void) {
        let interval = fireDate.timeIntervalSinceNow
        guard interval > 0 else {
            print("\(name) time already passed for today.")
            return
        }

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            handler()
        }

        // Assign to appropriate slot
        if name.contains("Morning") {
            morningTimer?.invalidate()
            morningTimer = timer
        } else {
            eveningTimer?.invalidate()
            eveningTimer = timer
        }

        RunLoop.main.add(timer, forMode: .common)
    }

    private func scheduleMidnightReschedule() {
        midnightTimer?.invalidate()

        let cal = Calendar.current
        let now = Date()
        // Reschedule a few minutes after midnight to ensure new day's times
        if let next = cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 5, second: 0), matchingPolicy: .nextTime) {
            let interval = max(0, next.timeIntervalSinceNow)
            midnightTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                if let loc = self.lastLocation {
                    self.scheduleGoldenHourEvents(for: loc.coordinate, on: Date())
                } else {
                    self.locationManager.requestLocation()
                }
                // Schedule again for the next day
                self.scheduleMidnightReschedule()
            }
            if let midnightTimer {
                RunLoop.main.add(midnightTimer, forMode: .common)
            }
        }
    }

    private func invalidateTimers() {
        morningTimer?.invalidate()
        eveningTimer?.invalidate()
        midnightTimer?.invalidate()
        morningTimer = nil
        eveningTimer = nil
        midnightTimer = nil
    }
}

// MARK: - CLLocationManagerDelegate
extension AppDelegate: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        requestLocationAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        handleNewLocation(loc)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error)")
    }
}
