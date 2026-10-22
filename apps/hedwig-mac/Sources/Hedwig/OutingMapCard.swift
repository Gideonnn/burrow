import AppKit
import CoreLocation
import HedwigCore
import MapKit
import SwiftUI

// The Waar part of an outing's page: a still map of the venue with a pin,
// its name and city, the travel time when this Mac may know where it is,
// and Route. Without a place (offline, not found) the page shows the plain
// line as before.

@MainActor
enum OutingMaps {
    static let book = PlaceBook(file: PlaceBook.defaultFile, search: search)

    static func search(_ query: String) async -> PlaceSearchResult {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { return .notFound }
            let coordinate = item.placemark.coordinate
            return .found(OutingPlace(
                latitude: coordinate.latitude, longitude: coordinate.longitude,
                name: item.name, city: item.placemark.locality))
        } catch let error as MKError where error.code == .placemarkNotFound {
            return .notFound
        } catch {
            return .failed
        }
    }

    static func mapItem(_ place: OutingPlace, name: String) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = name
        return item
    }

    // MARK: Snapshots

    private static var snapshots: [String: NSImage] = [:]
    private static var order: [String] = []

    static func snapshotKey(_ place: OutingPlace, size: CGSize, dark: Bool) -> String {
        "\(place.latitude),\(place.longitude)|\(Int(size.width))x\(Int(size.height))|\(dark ? "dark" : "light")"
    }

    static func cachedSnapshot(_ key: String) -> NSImage? { snapshots[key] }

    /// The pin stands a little above the middle, clear of the label.
    static let pinHeight: CGFloat = 0.44

    static func snapshot(_ place: OutingPlace, size: CGSize, dark: Bool) async -> NSImage? {
        let key = snapshotKey(place, size: size, dark: dark)
        if let hit = snapshots[key] { return hit }
        let options = MKMapSnapshotter.Options()
        var region = MKCoordinateRegion(
            center: place.coordinate, latitudinalMeters: 700, longitudinalMeters: 700 * size.width / size.height)
        region.center.latitude -= region.span.latitudeDelta * (0.5 - pinHeight)
        options.region = region
        options.size = size
        options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        options.pointOfInterestFilter = MKPointOfInterestFilter(including: [.parking, .publicTransport])
        guard let image = try? await MKMapSnapshotter(options: options).start().image else { return nil }
        snapshots[key] = image
        order.append(key)
        while order.count > 40 { snapshots[order.removeFirst()] = nil }
        return image
    }

    // MARK: Travel time

    private static var travelTimes: [String: (at: Date, text: String?)] = [:]

    /// Only with location access already given; this never asks by itself.
    static func travelTime(to place: OutingPlace, key: String) async -> String? {
        guard LocationAccess.shared.granted else { return nil }
        if let hit = travelTimes[key], hit.at.timeIntervalSinceNow > -15 * 60 { return hit.text }
        guard let here = await LocationAccess.shared.currentLocation() else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: here.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        request.transportType = .automobile
        guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
        let text = TravelTime.text(seconds: eta.expectedTravelTime)
        travelTimes[key] = (.now, text)
        return text
    }
}

extension OutingPlace {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Whether this Mac may use its location. It asks only when someone picks
/// "Toon reistijd" from the map's menu.
@MainActor @Observable
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private(set) var status: CLAuthorizationStatus

    override private init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var granted: Bool { status == .authorizedAlways || status == .authorized }
    var undecided: Bool { status == .notDetermined && Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil }

    func ask() { manager.requestWhenInUseAuthorization() }

    func currentLocation() async -> CLLocation? {
        if let last = manager.location, last.timestamp.timeIntervalSinceNow > -30 * 60 { return last }
        return await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let location = update.location { return location }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}

// MARK: The card

struct OutingMapCard: View {
    @Environment(\.colorScheme) private var scheme
    let outing: Outing
    let place: OutingPlace
    @State private var image: NSImage?
    @State private var width: CGFloat = 0
    @State private var travel: String?
    @State private var landed = false

    static let height: CGFloat = 196

    // Rounded up, so dragging the window does not draw a map per point.
    private var size: CGSize { CGSize(width: (width / 80).rounded(.up) * 80, height: Self.height) }
    private var snapshotKey: String { OutingMaps.snapshotKey(place, size: size, dark: scheme == .dark) }
    private var query: String { outing.placeQueries.first ?? outing.title }
    private var label: (title: String, subtitle: String?) { outing.placeLabel(place) }

    var body: some View {
        map
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .overlay(alignment: .bottomLeading) { caption.allowsHitTesting(false) }
            .overlay(alignment: .bottomTrailing) { routeButton }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.black.opacity(scheme == .dark ? 0.4 : 0.08)))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .task(id: snapshotKey) { await loadSnapshot() }
            .task(id: "\(outing.placeKey ?? "")|\(LocationAccess.shared.granted)") {
                travel = await OutingMaps.travelTime(to: place, key: outing.placeKey ?? query)
            }
            .contextMenu {
                Button("Open in Kaarten", action: openPlace)
                Button("Route", action: openRoute)
                if LocationAccess.shared.undecided {
                    Divider()
                    Button("Toon reistijd vanaf deze Mac") { LocationAccess.shared.ask() }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Kaart van \(label.title)")
    }

    private var map: some View {
        // The snapshot is a little wider than the card; as an overlay it
        // never widens the card itself.
        Rectangle().fill(.quaternary.opacity(0.5))
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
        .overlay {
            if image != nil {
                GeometryReader { geo in
                    MapPin(outing: outing)
                        .offset(y: landed ? 0 : -26)
                        .opacity(landed ? 1 : 0)
                        .position(x: geo.size.width / 2, y: geo.size.height * OutingMaps.pinHeight - MapPin.tip)
                }
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture(perform: openPlace)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Open in Kaarten")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.title).font(.headline).lineLimit(1)
            if let subtitle = label.subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if let travel {
                Label(travel, systemImage: "car.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    private var routeButton: some View {
        Button(action: openRoute) {
            Label("Route", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .frame(height: 30)
                .background(Color.pink, in: Capsule())
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Route in Kaarten")
        .padding(12)
    }

    private func loadSnapshot() async {
        guard width > 0 else { return }
        if let hit = OutingMaps.cachedSnapshot(snapshotKey) {
            image = hit
            landed = true
            return
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled, let fresh = await OutingMaps.snapshot(place, size: size, dark: scheme == .dark), !Task.isCancelled
        else { return }
        let first = image == nil
        withAnimation(.easeOut(duration: 0.25)) { image = fresh }
        if first {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.12)) { landed = true }
        }
    }

    private func openPlace() {
        NSWorkspace.shared.open(MapsLink.place(place, query: query))
    }

    private func openRoute() {
        OutingMaps.mapItem(place, name: label.title)
            .openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }
}

/// The card's size while the place is looked up for the first time, so the
/// page does not jump when the map arrives.
struct OutingMapPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(.quaternary.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: OutingMapCard.height)
            .overlay { Image(systemName: "map").font(.title2).foregroundStyle(.tertiary) }
            .accessibilityHidden(true)
    }
}

/// A round head with the outing's picture or its kind, on a short point.
private struct MapPin: View {
    let outing: Outing
    static let head: CGFloat = 44
    static let point: CGFloat = 10
    /// From the pin's centre down to its point.
    static var tip: CGFloat { (head + point - 2) / 2 }

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.black.opacity(0.22))
                .frame(width: 18, height: 6)
                .blur(radius: 2)
                .offset(y: Self.tip)
            VStack(spacing: -2) {
                face
                    .frame(width: Self.head - 6, height: Self.head - 6)
                    .clipShape(Circle())
                    .padding(3)
                    .background(Circle().fill(.white))
                Triangle()
                    .fill(.white)
                    .frame(width: 14, height: Self.point)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
        }
        .accessibilityHidden(true)
    }

    private var face: some View {
        OutingPictureReader(outing: outing) { picture in
            // A banner cropped to a circle is a few letters; the kind says more.
            if let picture, CGFloat(picture.width) / CGFloat(max(picture.height, 1)) < 1.5 {
                Color.clear.overlay { picture.swiftUI.resizable().scaledToFill() }
            } else {
                OutingArtFallback(outing: outing, symbolSize: 17)
            }
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
