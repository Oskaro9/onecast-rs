import Foundation
import GameController
import IOKit.hid
import OneCastCore

/// Reads native macOS `GCController` gamepads (with an `IOHIDManager` fallback for 8BitDo/BLE HID pads)
/// and forwards state to `OneCastCore` at 120Hz.
@MainActor
final class ControllerManager: ObservableObject {
    @Published var connectedControllerName: String?
    @Published var lastButtonsHex: String = "0000"

    private var activeController: GCController?
    private let hidFallback = IOHIDGamepadMonitor()
    private let pollQueue = DispatchQueue(label: "com.onecastoss.input.poll", qos: .userInteractive)
    private var pollTimer: DispatchSourceTimer?
    private var onState: (@Sendable (ControllerState) -> Void)?

    init() {
        GCController.shouldMonitorBackgroundEvents = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshControllers()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshControllers()
            }
        }

        hidFallback.onDeviceChanged = { [weak self] in
            Task { @MainActor in
                self?.refreshControllers()
            }
        }
        hidFallback.start()

        refreshControllers()
    }

    func startPolling(handler: @escaping @Sendable (ControllerState) -> Void) {
        onState = handler
        activeController?.extendedGamepad?.buttonHome?.preferredSystemGestureState = .disabled
        let storedHz = UserDefaults.standard.integer(forKey: "controllerPollHz")
        let hz = storedHz > 0 ? storedHz : 1000
        let intervalNs = max(1_000_000, 1_000_000_000 / hz)

        let hid = hidFallback
        var lastButtons: UInt16 = 0

        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(intervalNs), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            if let hidState = hid.currentStateIfConnected() {
                handler(hidState)
                if hidState.buttons != lastButtons {
                    lastButtons = hidState.buttons
                    let hex = String(format: "%04X", hidState.buttons)
                    DispatchQueue.main.async {
                        self?.lastButtonsHex = hex
                    }
                }
                return
            }

            if let state = self?.sampleActiveController() {
                handler(state)
                if state.buttons != lastButtons {
                    lastButtons = state.buttons
                    let hex = String(format: "%04X", state.buttons)
                    DispatchQueue.main.async {
                        self?.lastButtonsHex = hex
                    }
                }
            }
        }
        pollTimer = timer
        timer.resume()
    }

    func stopPolling() {
        pollTimer?.cancel()
        pollTimer = nil
        onState = nil
        activeController?.extendedGamepad?.buttonHome?.preferredSystemGestureState = .enabled
    }

    private func refreshControllers() {
        if let first = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            activeController = first
            connectedControllerName = first.vendorName ?? "Game Controller"
        } else if let hidName = hidFallback.connectedDeviceName {
            activeController = nil
            connectedControllerName = "\(hidName) (HID)"
        } else {
            activeController = nil
            connectedControllerName = nil
        }
    }

    private func sampleActiveController() -> ControllerState? {
        guard let pad = activeController?.extendedGamepad else { return nil }

        var buttons: UInt16 = 0
        if pad.buttonA.isPressed { buttons |= (1 << 4) }
        if pad.buttonB.isPressed { buttons |= (1 << 5) }
        if pad.buttonX.isPressed { buttons |= (1 << 6) }
        if pad.buttonY.isPressed { buttons |= (1 << 7) }
        if pad.dpad.up.isPressed { buttons |= (1 << 8) }
        if pad.dpad.down.isPressed { buttons |= (1 << 9) }
        if pad.dpad.left.isPressed { buttons |= (1 << 10) }
        if pad.dpad.right.isPressed { buttons |= (1 << 11) }
        if pad.leftShoulder.isPressed { buttons |= (1 << 12) }
        if pad.rightShoulder.isPressed { buttons |= (1 << 13) }
        if pad.leftThumbstickButton?.isPressed == true { buttons |= (1 << 14) }
        if pad.rightThumbstickButton?.isPressed == true { buttons |= (1 << 15) }
        if pad.buttonMenu.isPressed { buttons |= (1 << 2) }
        if pad.buttonOptions?.isPressed == true { buttons |= (1 << 3) }
        if pad.buttonHome?.isPressed == true { buttons |= (1 << 1) }

        return ControllerState(
            buttons: buttons,
            leftTrigger: pad.leftTrigger.value,
            rightTrigger: pad.rightTrigger.value,
            leftThumbX: pad.leftThumbstick.xAxis.value,
            leftThumbY: pad.leftThumbstick.yAxis.value,
            rightThumbX: pad.rightThumbstick.xAxis.value,
            rightThumbY: pad.rightThumbstick.yAxis.value
        )
    }
}

/// Direct `IOHIDManager` fallback for controllers (such as 8BitDo Ultimate 2 Wireless)
/// that expose standard HID GamePad usages without a `GCExtendedGamepad` profile.
private final class IOHIDGamepadMonitor {
    var onDeviceChanged: (() -> Void)?
    private var _connectedDeviceName: String?
    var connectedDeviceName: String? {
        lock.lock()
        defer { lock.unlock() }
        return _connectedDeviceName
    }

    private var manager: IOHIDManager?
    private let lock = NSLock()
    private var stickDeadzone: Double = 0.06
    private var state = ControllerState(
        buttons: 0,
        leftTrigger: 0,
        rightTrigger: 0,
        leftThumbX: 0,
        leftThumbY: 0,
        rightThumbX: 0,
        rightThumbY: 0
    )

    deinit {
        if let mgr = manager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func start() {
        stickDeadzone = UserDefaults.standard.object(forKey: "stickDeadzone") as? Double ?? 0.06
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let criteria: [[String: Any]] = [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_GamePad
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Joystick
            ]
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, criteria as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            let me = Unmanaged<IOHIDGamepadMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.handleDeviceMatched(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, _ in
            guard let ctx else { return }
            let me = Unmanaged<IOHIDGamepadMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.handleDeviceRemoved()
        }, ctx)

        IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
            guard let ctx else { return }
            let me = Unmanaged<IOHIDGamepadMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.handleInputValue(value)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = mgr
    }

    func currentStateIfConnected() -> ControllerState? {
        lock.lock()
        defer { lock.unlock() }
        guard _connectedDeviceName != nil else { return nil }
        return state
    }

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "HID Gamepad"
        lock.lock()
        _connectedDeviceName = name
        lock.unlock()
        onDeviceChanged?()
    }

    private func handleDeviceRemoved() {
        let newName: String?
        if let mgr = manager,
           let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
           let first = devices.first
        {
            newName = (IOHIDDeviceGetProperty(first, kIOHIDProductKey as CFString) as? String) ?? "HID Gamepad"
        } else {
            newName = nil
        }
        lock.lock()
        _connectedDeviceName = newName
        lock.unlock()
        onDeviceChanged?()
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let page = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intVal = IOHIDValueGetIntegerValue(value)
        let minVal = IOHIDElementGetLogicalMin(element)
        let maxVal = IOHIDElementGetLogicalMax(element)

        lock.lock()
        defer { lock.unlock() }

        if page == UInt32(kHIDPage_Button) {
            let pressed = intVal != 0
            let mask: UInt16
            switch usage {
            case 1: mask = 1 << 4   // A
            case 2: mask = 1 << 5   // B
            case 4: mask = 1 << 6   // X
            case 5: mask = 1 << 7   // Y
            case 7: mask = 1 << 12  // LB
            case 8: mask = 1 << 13  // RB
            case 11: mask = 1 << 3  // View
            case 12: mask = 1 << 2  // Menu
            case 13: mask = 1 << 1  // Nexus
            case 14: mask = 1 << 14 // L3
            case 15: mask = 1 << 15 // R3
            default: mask = 0
            }
            if pressed {
                state.buttons |= mask
            } else {
                state.buttons &= ~mask
            }
        } else if page == UInt32(kHIDPage_GenericDesktop) {
            let normAxis = normalizeSignedAxis(intVal, min: minVal, max: maxVal)
            switch usage {
            case UInt32(kHIDUsage_GD_X):
                state.leftThumbX = normAxis
            case UInt32(kHIDUsage_GD_Y):
                state.leftThumbY = -normAxis
            case UInt32(kHIDUsage_GD_Z):
                state.rightThumbX = normAxis
            case UInt32(kHIDUsage_GD_Rz):
                state.rightThumbY = -normAxis
            case UInt32(kHIDUsage_GD_Hatswitch):
                state.buttons &= ~((1 << 8) | (1 << 9) | (1 << 10) | (1 << 11))
                let hat = intVal - minVal
                switch hat {
                case 0: state.buttons |= (1 << 8)
                case 1: state.buttons |= (1 << 8) | (1 << 11)
                case 2: state.buttons |= (1 << 11)
                case 3: state.buttons |= (1 << 9) | (1 << 11)
                case 4: state.buttons |= (1 << 9)
                case 5: state.buttons |= (1 << 9) | (1 << 10)
                case 6: state.buttons |= (1 << 10)
                case 7: state.buttons |= (1 << 8) | (1 << 10)
                default: break
                }
            default:
                break
            }
        } else if page == UInt32(kHIDPage_Simulation) {
            let normTrig = normalizeUnsignedAxis(intVal, min: minVal, max: maxVal)
            switch usage {
            case 0xC5: // Brake -> LT
                state.leftTrigger = normTrig
            case 0xC4: // Accelerator -> RT
                state.rightTrigger = normTrig
            default:
                break
            }
        }
    }

    private func normalizeSignedAxis(_ val: CFIndex, min: CFIndex, max: CFIndex) -> Float {
        guard max > min else { return 0 }
        let mid = Double(min + max) / 2.0
        let half = Double(max - min) / 2.0
        let n = (Double(val) - mid) / half
        return abs(n) < stickDeadzone ? 0 : Float(Swift.max(-1.0, Swift.min(1.0, n)))
    }

    private func normalizeUnsignedAxis(_ val: CFIndex, min: CFIndex, max: CFIndex) -> Float {
        guard max > min else { return 0 }
        let n = Double(val - min) / Double(max - min)
        return Float(Swift.max(0.0, Swift.min(1.0, n)))
    }
}
