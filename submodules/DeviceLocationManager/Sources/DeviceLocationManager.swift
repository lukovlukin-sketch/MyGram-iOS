import Foundation
import CoreLocation
import SwiftSignalKit
import SGSimpleSettings

private typealias SignalKitTimer = SwiftSignalKit.Timer

public enum DeviceLocationMode: Int32 {
    case preciseForeground = 0
    case preciseAlways = 1
}

private final class DeviceLocationSubscriber {
    let id: Int32
    let mode: DeviceLocationMode
    let update: (CLLocation, Double?) -> Void
    
    init(id: Int32, mode: DeviceLocationMode, update: @escaping (CLLocation, Double?) -> Void) {
        self.id = id
        self.mode = mode
        self.update = update
    }
}

private func getTopMode(subscribers: [DeviceLocationSubscriber]) -> DeviceLocationMode? {
    var mode: DeviceLocationMode?
    for subscriber in subscribers {
        if mode == nil || subscriber.mode.rawValue > mode!.rawValue {
            mode = subscriber.mode
        }
    }
    return mode
}

public final class DeviceLocationManager: NSObject {
    private let queue: Queue
    private let log: ((String) -> Void)?
    
    private let manager: CLLocationManager
    private var requestedAuthorization = false
    
    private var nextSubscriberId: Int32 = 0
    private var subscribers: [DeviceLocationSubscriber] = []
    private var currentTopMode: DeviceLocationMode?
    
    private var currentLocation: CLLocation?
    private var currentHeading: CLHeading?
    private var fakeGpsTimer: SignalKitTimer?
    
    public init(queue: Queue, log: ((String) -> Void)? = nil) {
        assert(queue.isCurrent())
        
        self.queue = queue
        self.log = log
        self.manager = CLLocationManager()
        
        super.init()
        
        self.manager.delegate = self
        self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        self.manager.distanceFilter = kCLDistanceFilterNone
        self.manager.activityType = .other
        self.manager.pausesLocationUpdatesAutomatically = false
        self.manager.headingFilter = 2.0
        if #available(iOS 11.0, *) {
            self.manager.showsBackgroundLocationIndicator = true
        }
    }

    deinit {
        self.fakeGpsTimer?.invalidate()
    }

    private func makeFakeLocationSample() -> (CLLocation, Double?) {
        let sample = MyGramFakeGPSEngine.shared.currentSample()
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: sample.latitude, longitude: sample.longitude),
            altitude: 120.0,
            horizontalAccuracy: sample.horizontalAccuracy,
            verticalAccuracy: 10.0,
            course: sample.heading,
            speed: sample.speed,
            timestamp: Date()
        )
        return (location, sample.heading)
    }

    private func emitFakeLocation() {
        assert(self.queue.isCurrent())
        guard self.currentTopMode != nil else {
            return
        }
        let (fakeLocation, fakeHeading) = self.makeFakeLocationSample()
        self.currentLocation = fakeLocation
        for subscriber in self.subscribers {
            subscriber.update(fakeLocation, fakeHeading)
        }
    }

    private func startFakeGpsTimerIfNeeded() {
        if self.fakeGpsTimer == nil {
            let timer = SignalKitTimer(timeout: 2.0, repeat: true, completion: { [weak self] in
                guard let strongSelf = self else { return }
                if SGSimpleSettings.shared.fakeGpsEnabled && strongSelf.currentTopMode != nil {
                    strongSelf.emitFakeLocation()
                }
            }, queue: self.queue)
            self.fakeGpsTimer = timer
            timer.start()
        }
    }

    private func stopFakeGpsTimer() {
        self.fakeGpsTimer?.invalidate()
        self.fakeGpsTimer = nil
    }
    
    public func push(mode: DeviceLocationMode, updated: @escaping (CLLocation, Double?) -> Void) -> Disposable {
        assert(self.queue.isCurrent())
        
        let id = self.nextSubscriberId
        self.nextSubscriberId += 1
        self.subscribers.append(DeviceLocationSubscriber(id: id, mode: mode, update: updated))
        
        if SGSimpleSettings.shared.fakeGpsEnabled {
            let (fakeLocation, fakeHeading) = self.makeFakeLocationSample()
            self.currentLocation = fakeLocation
            updated(fakeLocation, fakeHeading)
        } else if let currentLocation = self.currentLocation {
            updated(currentLocation, self.currentHeading?.magneticHeading)
        }
        
        self.updateTopMode()
        
        let queue = self.queue
        return ActionDisposable { [weak queue, weak self] in
            if let queue = queue {
                queue.async {
                    if let strongSelf = self {
                        loop: for i in 0 ..< strongSelf.subscribers.count {
                            if strongSelf.subscribers[i].id == id {
                                strongSelf.subscribers.remove(at: i)
                                break loop
                            }
                        }
                        
                        strongSelf.updateTopMode()
                    }
                }
            }
        }
    }
    
    private func updateTopMode() {
        assert(self.queue.isCurrent())
        
        let previousTopMode = self.currentTopMode
        let topMode = getTopMode(subscribers: self.subscribers)
        if topMode != previousTopMode {
            self.currentTopMode = topMode
            if let topMode = topMode {
                self.log?("setting mode \(topMode)")
                switch topMode {
                case .preciseForeground:
                    self.manager.allowsBackgroundLocationUpdates = false
                case .preciseAlways:
                    self.manager.allowsBackgroundLocationUpdates = true
                }
                
                if previousTopMode == nil {
                    if !self.requestedAuthorization {
                        self.requestedAuthorization = true
                        self.manager.requestAlwaysAuthorization()
                    }

                    self.manager.startUpdatingLocation()
                    self.manager.startUpdatingHeading()
                }
                self.startFakeGpsTimerIfNeeded()
                if SGSimpleSettings.shared.fakeGpsEnabled {
                    self.emitFakeLocation()
                }
            } else {
                self.stopFakeGpsTimer()
                self.currentLocation = nil
                self.manager.stopUpdatingLocation()
                self.log?("stopped")
            }
        }
    }
}

extension CLHeading {
    var effectiveHeading: Double? {
        if self.headingAccuracy < 0.0 {
            return nil
        }
        if self.trueHeading > 0.0 {
            return self.trueHeading
        } else {
            return self.magneticHeading
        }
    }
}

extension DeviceLocationManager: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        assert(self.queue.isCurrent())

        if let realLocation = locations.first {
            MyGramFakeGPSEngine.shared.recordLastRealLocation(
                latitude: realLocation.coordinate.latitude,
                longitude: realLocation.coordinate.longitude
            )
        }

        if SGSimpleSettings.shared.fakeGpsEnabled {
            if let realLocation = locations.first {
                MyGramFakeGPSEngine.shared.captureFreezeCoordinateIfNeeded(
                    latitude: realLocation.coordinate.latitude,
                    longitude: realLocation.coordinate.longitude
                )
            }
            if self.currentTopMode != nil {
                self.emitFakeLocation()
            }
            return
        }
        
        if let location = locations.first {
            if self.currentTopMode != nil {
                self.currentLocation = location
                for subscriber in self.subscribers {
                    subscriber.update(location, self.currentHeading?.effectiveHeading)
                }
            }
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        assert(self.queue.isCurrent())

        if SGSimpleSettings.shared.fakeGpsEnabled {
            return
        }
        
        if self.currentTopMode != nil {
            self.currentHeading = newHeading
            if let currentLocation = self.currentLocation {
                for subscriber in self.subscribers {
                    subscriber.update(currentLocation, newHeading.effectiveHeading)
                }
            }
        }
    }
}

public func currentLocationManagerCoordinate(manager: DeviceLocationManager, timeout timeoutValue: Double) -> Signal<CLLocationCoordinate2D?, NoError> {
    return (
        Signal { subscriber in
            let disposable = manager.push(mode: .preciseForeground, updated: { location, _ in
                subscriber.putNext(location.coordinate)
                subscriber.putCompletion()
            })
            return disposable
        }
        |> runOn(Queue.mainQueue())
    )
    |> timeout(timeoutValue, queue: Queue.mainQueue(), alternate: .single(nil))
}
