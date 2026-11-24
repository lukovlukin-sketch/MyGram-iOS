import Foundation
import UIKit
import MapKit
import SGSimpleSettings

final class MyGramGPSMapPickerController: UIViewController, MKMapViewDelegate, UISearchBarDelegate {
    private enum PickerMode: Int {
        case singlePoint = 0
        case directRoute = 1
        case roadRoute = 2
    }

    private let isRussian: Bool
    private let onSave: () -> Void

    private let mapView = MKMapView()
    private let searchBar = UISearchBar()
    private let modeControl = UISegmentedControl()
    private let bottomCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let coordsLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)

    private var waypoints: [MyGramFakeGPSPoint] = []
    private var resolvedRoadPoints: [MyGramFakeGPSPoint] = []
    private var resolvedRoadDistanceMeters: Double = 0.0
    private var isCalculatingRoads: Bool = false
    private var roadRequestToken: Int = 0
    private var pickerMode: PickerMode = .singlePoint

    init(isRussian: Bool, onSave: @escaping () -> Void) {
        self.isRussian = isRussian
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)

        let existing = MyGramFakeGPSEngine.shared.parsePoints(from: SGSimpleSettings.shared.fakeGpsCoordinates)
        if !existing.isEmpty {
            self.waypoints = existing
        } else {
            self.waypoints = [MyGramFakeGPSPoint(latitude: 55.7558, longitude: 37.6173)]
        }
        if SGSimpleSettings.shared.fakeGpsMode == SGSimpleSettings.FakeGPSMode.loopRoute.rawValue || self.waypoints.count > 1 {
            self.pickerMode = .directRoute
        } else {
            self.pickerMode = .singlePoint
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = .systemBackground
        self.title = self.isRussian ? "Карта Fake GPS" : "Fake GPS Map"

        self.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(self.closeTapped)
        )
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: self.isRussian ? "Из буфера" : "Paste",
            style: .plain,
            target: self,
            action: #selector(self.pasteFromClipboardTapped)
        )

        self.setupUI()
        self.refreshMapOverlays()
        if let first = self.waypoints.first {
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                latitudinalMeters: 1200,
                longitudinalMeters: 1200
            )
            self.mapView.setRegion(region, animated: false)
        }
    }

    private func setupUI() {
        self.mapView.translatesAutoresizingMaskIntoConstraints = false
        self.mapView.delegate = self
        self.mapView.showsCompass = true
        self.mapView.showsScale = true
        self.view.addSubview(self.mapView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(self.handleMapTap(_:)))
        self.mapView.addGestureRecognizer(tapGesture)

        self.searchBar.translatesAutoresizingMaskIntoConstraints = false
        self.searchBar.delegate = self
        self.searchBar.searchBarStyle = .minimal
        self.searchBar.placeholder = self.isRussian ? "Поиск адреса или места..." : "Search address or place..."
        self.searchBar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        self.searchBar.layer.cornerRadius = 12
        self.searchBar.clipsToBounds = true
        self.view.addSubview(self.searchBar)

        self.modeControl.translatesAutoresizingMaskIntoConstraints = false
        self.modeControl.insertSegment(withTitle: self.isRussian ? "Точка" : "Point", at: 0, animated: false)
        self.modeControl.insertSegment(withTitle: self.isRussian ? "Прямая" : "Direct", at: 1, animated: false)
        self.modeControl.insertSegment(withTitle: self.isRussian ? "По дорогам" : "Roads", at: 2, animated: false)
        self.modeControl.selectedSegmentIndex = self.pickerMode.rawValue
        self.modeControl.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)
        self.modeControl.addTarget(self, action: #selector(self.modeChanged), for: .valueChanged)
        self.view.addSubview(self.modeControl)

        self.bottomCard.translatesAutoresizingMaskIntoConstraints = false
        self.bottomCard.layer.cornerRadius = 18
        self.bottomCard.clipsToBounds = true
        self.view.addSubview(self.bottomCard)

        self.coordsLabel.translatesAutoresizingMaskIntoConstraints = false
        self.coordsLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        self.coordsLabel.textColor = .label
        self.coordsLabel.numberOfLines = 2
        self.coordsLabel.textAlignment = .center
        self.bottomCard.contentView.addSubview(self.coordsLabel)

        self.clearButton.translatesAutoresizingMaskIntoConstraints = false
        self.clearButton.setTitle(self.isRussian ? "Сбросить" : "Clear", for: .normal)
        self.clearButton.setTitleColor(.systemRed, for: .normal)
        self.clearButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        self.clearButton.addTarget(self, action: #selector(self.clearTapped), for: .touchUpInside)
        self.bottomCard.contentView.addSubview(self.clearButton)

        self.saveButton.translatesAutoresizingMaskIntoConstraints = false
        self.saveButton.setTitle(self.isRussian ? "Сохранить" : "Save", for: .normal)
        self.saveButton.setTitleColor(.white, for: .normal)
        self.saveButton.backgroundColor = .systemBlue
        self.saveButton.layer.cornerRadius = 12
        self.saveButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        self.saveButton.addTarget(self, action: #selector(self.saveTapped), for: .touchUpInside)
        self.bottomCard.contentView.addSubview(self.saveButton)

        NSLayoutConstraint.activate([
            self.mapView.topAnchor.constraint(equalTo: self.view.topAnchor),
            self.mapView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            self.mapView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            self.mapView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),

            self.searchBar.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            self.searchBar.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 12),
            self.searchBar.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -12),
            self.searchBar.heightAnchor.constraint(equalToConstant: 44),

            self.modeControl.topAnchor.constraint(equalTo: self.searchBar.bottomAnchor, constant: 8),
            self.modeControl.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 12),
            self.modeControl.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -12),

            self.bottomCard.leadingAnchor.constraint(equalTo: self.view.leadingAnchor, constant: 12),
            self.bottomCard.trailingAnchor.constraint(equalTo: self.view.trailingAnchor, constant: -12),
            self.bottomCard.bottomAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.bottomAnchor, constant: -12),

            self.coordsLabel.topAnchor.constraint(equalTo: self.bottomCard.contentView.topAnchor, constant: 12),
            self.coordsLabel.leadingAnchor.constraint(equalTo: self.bottomCard.contentView.leadingAnchor, constant: 14),
            self.coordsLabel.trailingAnchor.constraint(equalTo: self.bottomCard.contentView.trailingAnchor, constant: -14),

            self.clearButton.topAnchor.constraint(equalTo: self.coordsLabel.bottomAnchor, constant: 10),
            self.clearButton.leadingAnchor.constraint(equalTo: self.bottomCard.contentView.leadingAnchor, constant: 14),
            self.clearButton.bottomAnchor.constraint(equalTo: self.bottomCard.contentView.bottomAnchor, constant: -12),
            self.clearButton.heightAnchor.constraint(equalToConstant: 44),
            self.clearButton.widthAnchor.constraint(equalToConstant: 96),

            self.saveButton.topAnchor.constraint(equalTo: self.coordsLabel.bottomAnchor, constant: 10),
            self.saveButton.leadingAnchor.constraint(equalTo: self.clearButton.trailingAnchor, constant: 10),
            self.saveButton.trailingAnchor.constraint(equalTo: self.bottomCard.contentView.trailingAnchor, constant: -14),
            self.saveButton.bottomAnchor.constraint(equalTo: self.bottomCard.contentView.bottomAnchor, constant: -12),
            self.saveButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func closeTapped() {
        self.dismiss(animated: true, completion: nil)
    }

    @objc private func pasteFromClipboardTapped() {
        let raw = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = MyGramFakeGPSEngine.shared.parsePoints(from: raw)
        guard let first = parsed.first else {
            let alert = UIAlertController(
                title: self.isRussian ? "Координаты не найдены" : "No Coordinates Found",
                message: self.isRussian
                    ? "Скопируйте ссылку из Яндекс / Google / Apple Карт или координаты вида «55.7558, 37.6173»."
                    : "Copy a link from Yandex / Google / Apple Maps or coordinates like '55.7558, 37.6173'.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))
            self.present(alert, animated: true, completion: nil)
            return
        }
        if self.pickerMode == .singlePoint {
            self.waypoints = [first]
            self.resolvedRoadPoints = []
        } else {
            self.waypoints.append(contentsOf: parsed)
            if self.pickerMode == .roadRoute && self.waypoints.count >= 2 {
                self.rebuildRoadRoute()
            }
        }
        self.refreshMapOverlays()
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
            latitudinalMeters: 900,
            longitudinalMeters: 900
        )
        self.mapView.setRegion(region, animated: true)
    }

    @objc private func modeChanged() {
        self.pickerMode = PickerMode(rawValue: self.modeControl.selectedSegmentIndex) ?? .singlePoint
        self.resolvedRoadPoints = []
        self.resolvedRoadDistanceMeters = 0.0
        if self.pickerMode == .singlePoint, let first = self.waypoints.first {
            self.waypoints = [first]
        }
        if self.pickerMode == .roadRoute && self.waypoints.count >= 2 {
            self.rebuildRoadRoute()
        }
        self.refreshMapOverlays()
    }

    @objc private func handleMapTap(_ recognizer: UITapGestureRecognizer) {
        self.searchBar.resignFirstResponder()
        let locationInView = recognizer.location(in: self.mapView)
        let coord = self.mapView.convert(locationInView, toCoordinateFrom: self.mapView)
        let tapped = MyGramFakeGPSPoint(latitude: coord.latitude, longitude: coord.longitude)
        if self.pickerMode == .singlePoint {
            self.waypoints = [tapped]
            self.resolvedRoadPoints = []
        } else {
            self.waypoints.append(tapped)
            if self.pickerMode == .roadRoute && self.waypoints.count >= 2 {
                self.rebuildRoadRoute()
            }
        }
        self.refreshMapOverlays()
    }

    @objc private func clearTapped() {
        if self.pickerMode != .singlePoint && self.waypoints.count > 1 {
            self.waypoints.removeLast()
        } else {
            self.waypoints.removeAll()
        }
        self.resolvedRoadPoints = []
        self.resolvedRoadDistanceMeters = 0.0
        if self.pickerMode == .roadRoute && self.waypoints.count >= 2 {
            self.rebuildRoadRoute()
        }
        self.refreshMapOverlays()
    }

    @objc private func saveTapped() {
        let finalPoints: [MyGramFakeGPSPoint]
        if self.pickerMode == .roadRoute && self.resolvedRoadPoints.count >= 2 {
            finalPoints = self.resolvedRoadPoints
        } else {
            finalPoints = self.waypoints
        }
        guard !finalPoints.isEmpty else {
            return
        }
        let serialized = finalPoints.map { String(format: "%.6f, %.6f", $0.latitude, $0.longitude) }.joined(separator: "; ")
        SGSimpleSettings.shared.fakeGpsCoordinates = serialized
        if self.pickerMode != .singlePoint && finalPoints.count >= 2 {
            if SGSimpleSettings.shared.fakeGpsMode != SGSimpleSettings.FakeGPSMode.pingPong.rawValue {
                SGSimpleSettings.shared.fakeGpsMode = SGSimpleSettings.FakeGPSMode.loopRoute.rawValue
            }
        } else if self.pickerMode == .singlePoint && (SGSimpleSettings.shared.fakeGpsMode == SGSimpleSettings.FakeGPSMode.loopRoute.rawValue || SGSimpleSettings.shared.fakeGpsMode == SGSimpleSettings.FakeGPSMode.pingPong.rawValue) {
            SGSimpleSettings.shared.fakeGpsMode = SGSimpleSettings.FakeGPSMode.staticPoint.rawValue
        }
        MyGramFakeGPSEngine.shared.resetLoopClock()
        self.onSave()
        self.dismiss(animated: true, completion: nil)
    }

    private func rebuildRoadRoute() {
        guard self.waypoints.count >= 2 else { return }
        self.roadRequestToken += 1
        let token = self.roadRequestToken
        self.isCalculatingRoads = true
        self.refreshMapOverlays()

        let isPingPong = SGSimpleSettings.shared.fakeGpsMode == SGSimpleSettings.FakeGPSMode.pingPong.rawValue
        let legsCount = isPingPong ? (self.waypoints.count - 1) : self.waypoints.count
        var legResults: [[MyGramFakeGPSPoint]?] = Array(repeating: nil, count: legsCount)
        var legDistances: [Double] = Array(repeating: 0.0, count: legsCount)
        let group = DispatchGroup()
        let isCar = SGSimpleSettings.shared.fakeGpsSpeed == SGSimpleSettings.FakeGPSSpeed.car.rawValue

        for i in 0 ..< legsCount {
            let from = self.waypoints[i]
            let to = self.waypoints[(i + 1) % self.waypoints.count]
            group.enter()
            let req = MKDirections.Request()
            req.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: from.latitude, longitude: from.longitude)))
            req.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: to.latitude, longitude: to.longitude)))
            req.transportType = isCar ? .automobile : .walking
            let directions = MKDirections(request: req)
            directions.calculate { response, _ in
                if let route = response?.routes.first {
                    let count = route.polyline.pointCount
                    var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: count)
                    route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
                    legResults[i] = coords.map { MyGramFakeGPSPoint(latitude: $0.latitude, longitude: $0.longitude) }
                    legDistances[i] = route.distance
                } else {
                    legResults[i] = [from, to]
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self, self.roadRequestToken == token else { return }
            self.isCalculatingRoads = false
            var combined: [MyGramFakeGPSPoint] = []
            for leg in legResults {
                if let pts = leg {
                    combined.append(contentsOf: pts)
                }
            }
            self.resolvedRoadPoints = self.downsample(points: combined, maxCount: 120)
            self.resolvedRoadDistanceMeters = legDistances.reduce(0.0, +)
            self.refreshMapOverlays()
        }
    }

    private func downsample(points: [MyGramFakeGPSPoint], maxCount: Int) -> [MyGramFakeGPSPoint] {
        guard points.count > maxCount, maxCount >= 2 else {
            return points
        }
        let step = Double(points.count - 1) / Double(maxCount - 1)
        var result: [MyGramFakeGPSPoint] = []
        for i in 0 ..< maxCount {
            let idx = min(points.count - 1, Int(round(Double(i) * step)))
            result.append(points[idx])
        }
        return result
    }

    private func refreshMapOverlays() {
        self.mapView.removeAnnotations(self.mapView.annotations)
        self.mapView.removeOverlays(self.mapView.overlays)

        for (index, point) in self.waypoints.enumerated() {
            let annotation = MKPointAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            annotation.title = self.pickerMode == .singlePoint
                ? (self.isRussian ? "Точка Fake GPS" : "Fake GPS Point")
                : "#\(index + 1)"
            self.mapView.addAnnotation(annotation)
        }

        if self.pickerMode == .roadRoute && self.resolvedRoadPoints.count >= 2 {
            let coords = self.resolvedRoadPoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            self.mapView.addOverlay(polyline)
        } else if self.pickerMode != .singlePoint && self.waypoints.count >= 2 {
            var coords = self.waypoints.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            if let first = coords.first {
                coords.append(first)
            }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            self.mapView.addOverlay(polyline)
        } else if self.pickerMode == .singlePoint, let first = self.waypoints.first,
                  SGSimpleSettings.shared.fakeGpsMode == SGSimpleSettings.FakeGPSMode.circleWalk.rawValue {
            let radius = Double(SGSimpleSettings.shared.fakeGpsCircleRadius) ?? 150.0
            let circle = MKCircle(center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude), radius: radius)
            self.mapView.addOverlay(circle)
        }

        if self.waypoints.isEmpty {
            self.coordsLabel.text = self.isRussian ? "Нажмите на карту, чтобы поставить точку" : "Tap on the map to place a pin"
            self.saveButton.isEnabled = false
            self.saveButton.alpha = 0.5
        } else if self.pickerMode == .roadRoute {
            if self.isCalculatingRoads {
                self.coordsLabel.text = self.isRussian ? "Прокладываю маршрут по дорогам..." : "Building street route..."
            } else if self.resolvedRoadDistanceMeters > 0 {
                let km = String(format: "%.2f", self.resolvedRoadDistanceMeters / 1000.0)
                self.coordsLabel.text = self.isRussian
                    ? "По дорогам · \(self.waypoints.count) точек (\(km) км)"
                    : "Street route · \(self.waypoints.count) pins (\(km) km)"
            } else {
                self.coordsLabel.text = self.isRussian
                    ? "Поставьте минимум 2 точки на карте"
                    : "Place at least 2 pins on the map"
            }
            self.saveButton.isEnabled = !self.isCalculatingRoads
            self.saveButton.alpha = self.isCalculatingRoads ? 0.5 : 1.0
        } else if self.pickerMode == .directRoute {
            self.coordsLabel.text = self.isRussian
                ? "Точек в маршруте: \(self.waypoints.count) (тапните по карте)"
                : "Route waypoints: \(self.waypoints.count) (tap map to add)"
            self.saveButton.isEnabled = true
            self.saveButton.alpha = 1.0
        } else if let p = self.waypoints.first {
            self.coordsLabel.text = String(format: "%.6f, %.6f", p.latitude, p.longitude)
            self.saveButton.isEnabled = true
            self.saveButton.alpha = 1.0
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 4.0
            return renderer
        }
        if let circle = overlay as? MKCircle {
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = .systemBlue
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.15)
            renderer.lineWidth = 2.0
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        guard let query = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = self.mapView.region
        let search = MKLocalSearch(request: request)
        search.start { [weak self] response, _ in
            guard let self = self, let item = response?.mapItems.first else {
                return
            }
            let coord = item.placemark.coordinate
            let found = MyGramFakeGPSPoint(latitude: coord.latitude, longitude: coord.longitude)
            DispatchQueue.main.async {
                if self.pickerMode == .singlePoint {
                    self.waypoints = [found]
                    self.resolvedRoadPoints = []
                } else {
                    self.waypoints.append(found)
                    if self.pickerMode == .roadRoute && self.waypoints.count >= 2 {
                        self.rebuildRoadRoute()
                    }
                }
                self.refreshMapOverlays()
                let region = MKCoordinateRegion(center: coord, latitudinalMeters: 900, longitudinalMeters: 900)
                self.mapView.setRegion(region, animated: true)
            }
        }
    }
}
