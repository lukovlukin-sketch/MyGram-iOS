import Foundation
import MapKit

public struct MyGramFakeGPSPoint: Equatable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct MyGramFakeGPSPreset: Codable, Equatable {
    public let name: String
    public let coordinates: String
    public let mode: String

    public init(name: String, coordinates: String, mode: String) {
        self.name = name
        self.coordinates = coordinates
        self.mode = mode
    }
}

public struct MyGramFakeGPSSample {
    public let latitude: Double
    public let longitude: Double
    public let heading: Double
    public let speed: Double
    public let horizontalAccuracy: Double
}

public final class MyGramFakeGPSEngine {
    public static let shared = MyGramFakeGPSEngine()
    private static let fallbackPoint = MyGramFakeGPSPoint(latitude: 55.7558, longitude: 37.6173)

    private let realLocLock = NSLock()
    private var lastRealLocation: MyGramFakeGPSPoint?

    private init() {}

    public func recordLastRealLocation(latitude: Double, longitude: Double) {
        self.realLocLock.lock()
        self.lastRealLocation = MyGramFakeGPSPoint(latitude: latitude, longitude: longitude)
        self.realLocLock.unlock()
    }

    public func currentOriginPoint() -> MyGramFakeGPSPoint {
        if SGSimpleSettings.shared.fakeGpsEnabled {
            let sample = self.currentSample()
            return MyGramFakeGPSPoint(latitude: sample.latitude, longitude: sample.longitude)
        }
        self.realLocLock.lock()
        let real = self.lastRealLocation
        self.realLocLock.unlock()
        if let real = real {
            return real
        }
        return self.parsePoints(from: SGSimpleSettings.shared.fakeGpsCoordinates).first ?? MyGramFakeGPSEngine.fallbackPoint
    }

    public func startCarRoute(to destination: MyGramFakeGPSPoint, completion: @escaping (_ distanceMeters: Double, _ etaSeconds: TimeInterval) -> Void) {
        let origin = self.currentOriginPoint()
        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
        req.transportType = .automobile

        let directions = MKDirections(request: req)
        directions.calculate { response, _ in
            var routePoints: [MyGramFakeGPSPoint] = [origin, destination]
            var distance = self.distanceMeters(origin, destination)
            var eta = distance / 12.5

            if let route = response?.routes.first {
                let count = route.polyline.pointCount
                var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: count)
                route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
                let rawPoints = coords.map { MyGramFakeGPSPoint(latitude: $0.latitude, longitude: $0.longitude) }
                if rawPoints.count >= 2 {
                    routePoints = self.downsamplePoints(rawPoints, maxCount: 150)
                }
                distance = route.distance
                eta = route.expectedTravelTime
            }

            let serialized = routePoints.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) }.joined(separator: "; ")
            SGSimpleSettings.shared.fakeGpsCoordinates = serialized
            SGSimpleSettings.shared.fakeGpsSpeed = SGSimpleSettings.FakeGPSSpeed.car.rawValue
            SGSimpleSettings.shared.fakeGpsMode = SGSimpleSettings.FakeGPSMode.driveToTarget.rawValue
            SGSimpleSettings.shared.fakeGpsEnabled = true
            self.resetLoopClock()

            DispatchQueue.main.async {
                completion(distance, eta)
            }
        }
    }

    private func downsamplePoints(_ points: [MyGramFakeGPSPoint], maxCount: Int) -> [MyGramFakeGPSPoint] {
        guard points.count > maxCount, maxCount >= 2 else { return points }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var result: [MyGramFakeGPSPoint] = []
        for i in 0 ..< maxCount {
            let idx = min(points.count - 1, Int(round(Double(i) * step)))
            result.append(points[idx])
        }
        return result
    }

    public func parsePoints(from raw: String) -> [MyGramFakeGPSPoint] {
        if let fromLink = self.extractPointFromMapLink(raw) {
            return [fromLink]
        }
        let separators = CharacterSet(charactersIn: ";\n")
        let chunks = raw.components(separatedBy: separators)
        var result: [MyGramFakeGPSPoint] = []
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let fromLink = self.extractPointFromMapLink(trimmed) {
                result.append(fromLink)
                continue
            }
            let parts = trimmed
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2,
               let lat = Double(parts[0]),
               let lon = Double(parts[1]),
               lat >= -90.0, lat <= 90.0,
               lon >= -180.0, lon <= 180.0 {
                result.append(MyGramFakeGPSPoint(latitude: lat, longitude: lon))
            }
        }
        return result
    }

    /// Extracts (lat, lon) from Yandex Maps, Google Maps, or Apple Maps URLs.
    public func extractPointFromMapLink(_ raw: String) -> MyGramFakeGPSPoint? {
        let decoded = raw.removingPercentEncoding ?? raw
        let lower = decoded.lowercased()
        guard lower.contains("http") || lower.contains("maps.") || lower.contains("yandex") || lower.contains("google") || lower.contains("apple") else {
            return nil
        }

        // Google Maps exact pin: !3dLAT!4dLON
        if let pair = self.firstRegexPair(in: decoded, pattern: #"!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)"#) {
            return self.validatedPoint(lat: pair.0, lon: pair.1)
        }
        // Google Maps viewport: @LAT,LON
        if let pair = self.firstRegexPair(in: decoded, pattern: #"@(-?\d+\.\d+),(-?\d+\.\d+)"#) {
            return self.validatedPoint(lat: pair.0, lon: pair.1)
        }
        // Yandex Maps uses LON,LAT in ll=, pt=, whatshere[point]=
        if lower.contains("yandex") {
            if let pair = self.firstRegexPair(in: decoded, pattern: #"(?:whatshere\[point\]|pt|ll)=(-?\d+\.\d+),(-?\d+\.\d+)"#) {
                return self.validatedPoint(lat: pair.1, lon: pair.0)
            }
        }
        // Apple Maps & Google query params: ll=LAT,LON / coordinate=LAT,LON / q=LAT,LON / query=LAT,LON
        if let pair = self.firstRegexPair(in: decoded, pattern: #"(?:ll|coordinate|q|query)=(-?\d+\.\d+),(-?\d+\.\d+)"#) {
            return self.validatedPoint(lat: pair.0, lon: pair.1)
        }
        return nil
    }

    private func firstRegexPair(in text: String, pattern: String) -> (Double, Double)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges >= 3,
              let r1 = Range(match.range(at: 1), in: text),
              let r2 = Range(match.range(at: 2), in: text),
              let v1 = Double(text[r1]),
              let v2 = Double(text[r2]) else {
            return nil
        }
        return (v1, v2)
    }

    private func validatedPoint(lat: Double, lon: Double) -> MyGramFakeGPSPoint? {
        guard lat >= -90.0, lat <= 90.0, lon >= -180.0, lon <= 180.0 else {
            return nil
        }
        return MyGramFakeGPSPoint(latitude: lat, longitude: lon)
    }

    public func captureFreezeCoordinateIfNeeded(latitude: Double, longitude: Double) {
        let settings = SGSimpleSettings.shared
        guard settings.fakeGpsEnabled,
              settings.fakeGpsMode == SGSimpleSettings.FakeGPSMode.freezeCurrent.rawValue,
              settings.fakeGpsFrozenCoord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        settings.fakeGpsFrozenCoord = String(format: "%.6f, %.6f", latitude, longitude)
    }

    public func resetFreezeCoordinate() {
        SGSimpleSettings.shared.fakeGpsFrozenCoord = ""
    }

    public func resetLoopClock() {
        SGSimpleSettings.shared.fakeGpsLoopStartTime = Date().timeIntervalSince1970
    }

    public func allPresets() -> [MyGramFakeGPSPreset] {
        let raw = SGSimpleSettings.shared.fakeGpsPresetsJson
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MyGramFakeGPSPreset].self, from: data) else {
            return []
        }
        return decoded
    }

    public func savePreset(name: String, coordinates: String, mode: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        var presets = self.allPresets().filter { $0.name != trimmedName }
        presets.append(MyGramFakeGPSPreset(name: trimmedName, coordinates: coordinates, mode: mode))
        if let data = try? JSONEncoder().encode(presets),
           let str = String(data: data, encoding: .utf8) {
            SGSimpleSettings.shared.fakeGpsPresetsJson = str
        }
    }

    public func deletePreset(name: String) {
        let presets = self.allPresets().filter { $0.name != name }
        if let data = try? JSONEncoder().encode(presets),
           let str = String(data: data, encoding: .utf8) {
            SGSimpleSettings.shared.fakeGpsPresetsJson = str
        }
    }

    /// Rare realistic pauses: every ~3.5 minutes (210s) of movement, pause for 12s (traffic light / crosswalk).
    private func effectiveMotionState(elapsed: Double, smartPauses: Bool) -> (effectiveTime: Double, isPaused: Bool) {
        guard smartPauses else {
            return (elapsed, false)
        }
        let moveDuration = 210.0
        let pauseDuration = 12.0
        let cycle = moveDuration + pauseDuration
        let completedCycles = floor(elapsed / cycle)
        let inCycle = elapsed - completedCycles * cycle
        if inCycle <= moveDuration {
            return (completedCycles * moveDuration + inCycle, false)
        } else {
            return ((completedCycles + 1.0) * moveDuration, true)
        }
    }

    public func currentSample(now: TimeInterval = Date().timeIntervalSince1970) -> MyGramFakeGPSSample {
        let settings = SGSimpleSettings.shared
        let mode = SGSimpleSettings.FakeGPSMode(rawValue: settings.fakeGpsMode) ?? .staticPoint
        let speedMetersPerSec = self.speedValue(for: settings.fakeGpsSpeed)
        let radiusMeters = Double(settings.fakeGpsCircleRadius) ?? 150.0

        var startTime = settings.fakeGpsLoopStartTime
        if startTime <= 0.0 {
            startTime = now
            settings.fakeGpsLoopStartTime = startTime
        }
        let elapsed = max(0.0, now - startTime)
        let (effectiveElapsed, isPaused) = self.effectiveMotionState(elapsed: elapsed, smartPauses: settings.fakeGpsSmartPauses)

        let customPoints = self.parsePoints(from: settings.fakeGpsCoordinates)
        let primaryPoint = customPoints.first ?? MyGramFakeGPSEngine.fallbackPoint

        var lat = primaryPoint.latitude
        var lon = primaryPoint.longitude
        var heading: Double = 0.0
        var speed: Double = 0.0

        switch mode {
        case .staticPoint:
            lat = primaryPoint.latitude
            lon = primaryPoint.longitude
            heading = 0.0
            speed = 0.0

        case .freezeCurrent:
            let frozenPoints = self.parsePoints(from: settings.fakeGpsFrozenCoord)
            let target = frozenPoints.first ?? primaryPoint
            lat = target.latitude
            lon = target.longitude
            heading = 0.0
            speed = 0.0

        case .circleWalk:
            let safeRadius = max(20.0, radiusMeters)
            let angularSpeed = speedMetersPerSec / safeRadius
            let angle = (effectiveElapsed * angularSpeed).truncatingRemainder(dividingBy: 2.0 * Double.pi)
            let dNorth = safeRadius * cos(angle)
            let dEast = safeRadius * sin(angle)
            let shifted = self.offsetCoordinate(base: primaryPoint, northMeters: dNorth, eastMeters: dEast)
            lat = shifted.latitude
            lon = shifted.longitude
            let tangentDeg = ((angle * 180.0 / Double.pi) + 90.0).truncatingRemainder(dividingBy: 360.0)
            heading = tangentDeg >= 0.0 ? tangentDeg : tangentDeg + 360.0
            speed = isPaused ? 0.0 : speedMetersPerSec

        case .loopRoute:
            var route = customPoints
            if route.isEmpty {
                route = [primaryPoint]
            }
            if route.count == 1 {
                let second = self.offsetCoordinate(base: route[0], northMeters: max(60.0, radiusMeters), eastMeters: 0.0)
                route.append(second)
            }
            let (point, bearing) = self.interpolateClosedLoop(points: route, distanceTraveled: effectiveElapsed * speedMetersPerSec)
            lat = point.latitude
            lon = point.longitude
            heading = bearing
            speed = isPaused ? 0.0 : speedMetersPerSec

        case .pingPong:
            var route = customPoints
            if route.isEmpty {
                route = [primaryPoint]
            }
            if route.count == 1 {
                let second = self.offsetCoordinate(base: route[0], northMeters: max(120.0, radiusMeters), eastMeters: 0.0)
                route.append(second)
            }
            let (point, bearing, endpointPaused) = self.interpolatePingPong(
                points: route,
                elapsedSeconds: effectiveElapsed,
                speedMetersPerSec: speedMetersPerSec,
                endpointPauseSeconds: 90.0
            )
            lat = point.latitude
            lon = point.longitude
            heading = bearing
            speed = (endpointPaused || isPaused) ? 0.0 : speedMetersPerSec

        case .driveToTarget:
            let route = customPoints.isEmpty ? [primaryPoint] : customPoints
            let (point, bearing, arrived) = self.interpolateOneWay(points: route, distanceTraveled: effectiveElapsed * speedMetersPerSec)
            lat = point.latitude
            lon = point.longitude
            heading = bearing
            speed = (arrived || isPaused) ? 0.0 : speedMetersPerSec
        }

        if settings.fakeGpsJitter {
            // Smooth low-amplitude GPS drift (~2.5 meters) so the pin looks realistic
            let jitterNorth = sin(now * 0.37) * 1.8 + cos(now * 0.91) * 0.9
            let jitterEast = cos(now * 0.43) * 1.8 + sin(now * 0.83) * 0.9
            let drifted = self.offsetCoordinate(
                base: MyGramFakeGPSPoint(latitude: lat, longitude: lon),
                northMeters: jitterNorth,
                eastMeters: jitterEast
            )
            lat = drifted.latitude
            lon = drifted.longitude
        }

        return MyGramFakeGPSSample(
            latitude: lat,
            longitude: lon,
            heading: heading,
            speed: speed,
            horizontalAccuracy: settings.fakeGpsJitter ? 6.5 : 5.0
        )
    }

    private func speedValue(for raw: String) -> Double {
        switch SGSimpleSettings.FakeGPSSpeed(rawValue: raw) ?? .walk {
        case .walk:
            return 1.4 // ~5 km/h
        case .bike:
            return 4.2 // ~15 km/h
        case .car:
            return 12.5 // ~45 km/h
        }
    }

    private func offsetCoordinate(base: MyGramFakeGPSPoint, northMeters: Double, eastMeters: Double) -> MyGramFakeGPSPoint {
        let earthRadius = 6378137.0
        let dLat = (northMeters / earthRadius) * (180.0 / Double.pi)
        let cosLat = max(0.01, cos(base.latitude * Double.pi / 180.0))
        let dLon = (eastMeters / (earthRadius * cosLat)) * (180.0 / Double.pi)
        let newLat = min(90.0, max(-90.0, base.latitude + dLat))
        var newLon = base.longitude + dLon
        if newLon > 180.0 { newLon -= 360.0 }
        if newLon < -180.0 { newLon += 360.0 }
        return MyGramFakeGPSPoint(latitude: newLat, longitude: newLon)
    }

    private func distanceMeters(_ a: MyGramFakeGPSPoint, _ b: MyGramFakeGPSPoint) -> Double {
        let r = 6371000.0
        let lat1 = a.latitude * Double.pi / 180.0
        let lat2 = b.latitude * Double.pi / 180.0
        let dLat = (b.latitude - a.latitude) * Double.pi / 180.0
        let dLon = (b.longitude - a.longitude) * Double.pi / 180.0
        let sinDLat = sin(dLat / 2.0)
        let sinDLon = sin(dLon / 2.0)
        let h = sinDLat * sinDLat + cos(lat1) * cos(lat2) * sinDLon * sinDLon
        return 2.0 * r * atan2(sqrt(h), sqrt(max(0.0, 1.0 - h)))
    }

    private func bearingDegrees(_ a: MyGramFakeGPSPoint, _ b: MyGramFakeGPSPoint) -> Double {
        let lat1 = a.latitude * Double.pi / 180.0
        let lat2 = b.latitude * Double.pi / 180.0
        let dLon = (b.longitude - a.longitude) * Double.pi / 180.0
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180.0 / Double.pi
        return deg >= 0.0 ? deg : deg + 360.0
    }

    private func interpolateClosedLoop(points: [MyGramFakeGPSPoint], distanceTraveled: Double) -> (MyGramFakeGPSPoint, Double) {
        guard points.count >= 2 else {
            return (points.first ?? MyGramFakeGPSEngine.fallbackPoint, 0.0)
        }
        var segments: [(from: MyGramFakeGPSPoint, to: MyGramFakeGPSPoint, length: Double)] = []
        var totalLength = 0.0
        for i in 0 ..< points.count {
            let from = points[i]
            let to = points[(i + 1) % points.count]
            let len = self.distanceMeters(from, to)
            if len > 0.5 {
                segments.append((from, to, len))
                totalLength += len
            }
        }
        guard totalLength > 0.5 else {
            return (points[0], 0.0)
        }
        var remaining = distanceTraveled.truncatingRemainder(dividingBy: totalLength)
        for seg in segments {
            if remaining <= seg.length {
                let fraction = remaining / seg.length
                let lat = seg.from.latitude + (seg.to.latitude - seg.from.latitude) * fraction
                let lon = seg.from.longitude + (seg.to.longitude - seg.from.longitude) * fraction
                let bearing = self.bearingDegrees(seg.from, seg.to)
                return (MyGramFakeGPSPoint(latitude: lat, longitude: lon), bearing)
            }
            remaining -= seg.length
        }
        return (points[0], 0.0)
    }

    private func interpolateOneWay(points: [MyGramFakeGPSPoint], distanceTraveled: Double) -> (MyGramFakeGPSPoint, Double, Bool) {
        guard points.count >= 2 else {
            return (points.first ?? MyGramFakeGPSEngine.fallbackPoint, 0.0, true)
        }
        var remaining = max(0.0, distanceTraveled)
        var lastBearing = 0.0
        for i in 0 ..< (points.count - 1) {
            let from = points[i]
            let to = points[i + 1]
            let len = self.distanceMeters(from, to)
            guard len > 0.5 else { continue }
            lastBearing = self.bearingDegrees(from, to)
            if remaining <= len {
                let fraction = remaining / len
                let lat = from.latitude + (to.latitude - from.latitude) * fraction
                let lon = from.longitude + (to.longitude - from.longitude) * fraction
                return (MyGramFakeGPSPoint(latitude: lat, longitude: lon), lastBearing, false)
            }
            remaining -= len
        }
        return (points[points.count - 1], lastBearing, true)
    }

    private func interpolatePingPong(
        points: [MyGramFakeGPSPoint],
        elapsedSeconds: Double,
        speedMetersPerSec: Double,
        endpointPauseSeconds: Double
    ) -> (MyGramFakeGPSPoint, Double, Bool) {
        guard points.count >= 2 else {
            return (points.first ?? MyGramFakeGPSEngine.fallbackPoint, 0.0, true)
        }
        var totalLength = 0.0
        for i in 0 ..< (points.count - 1) {
            totalLength += self.distanceMeters(points[i], points[i + 1])
        }
        guard totalLength > 0.5, speedMetersPerSec > 0.05 else {
            return (points[0], 0.0, true)
        }
        let legDuration = totalLength / speedMetersPerSec
        let fullCycle = 2.0 * (legDuration + endpointPauseSeconds)
        let t = elapsedSeconds.truncatingRemainder(dividingBy: fullCycle)

        if t <= legDuration {
            let (p, b, _) = self.interpolateOneWay(points: points, distanceTraveled: t * speedMetersPerSec)
            return (p, b, false)
        } else if t <= legDuration + endpointPauseSeconds {
            return (points[points.count - 1], 0.0, true)
        } else if t <= 2.0 * legDuration + endpointPauseSeconds {
            let backTime = t - (legDuration + endpointPauseSeconds)
            let reversedPoints = Array(points.reversed())
            let (p, b, _) = self.interpolateOneWay(points: reversedPoints, distanceTraveled: backTime * speedMetersPerSec)
            return (p, b, false)
        } else {
            return (points[0], 0.0, true)
        }
    }
}
