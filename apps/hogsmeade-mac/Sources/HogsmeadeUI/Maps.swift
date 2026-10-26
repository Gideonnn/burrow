import AppKit
import CoreLocation
import HogsmeadeCore
import MapKit
import SwiftUI

// Where an outing is: Hedwig's place book (the same file, so a place found
// in one app is known in the other), a still map with a pin, the travel
// time when this Mac may know where it is, and Route in Apple Maps.

@MainActor
public enum OutingMaps {
    public static let book = PlaceBook(file: PlaceBook.defaultFile, search: search)

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

    public static func openPlace(_ place: OutingPlace, query: String) {
        NSWorkspace.shared.open(MapsLink.place(place, query: query))
    }

    public static func openRoute(to place: OutingPlace, name: String) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
    }

    private static var snapshots: [String: NSImage] = [:]
    private static var order: [String] = []

    static func snapshotKey(_ place: OutingPlace, size: CGSize, dark: Bool) -> String {
        "\(place.latitude),\(place.longitude)|\(Int(size.width))x\(Int(size.height))|\(dark ? "dark" : "light")"
    }

    /// Where the pin's point stands, as a share of the map's height.
    static let pinHeight: CGFloat = 0.62

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

    private static var travelTimes: [String: (at: Date, text: String?)] = [:]

    /// Only with location access already given; this never asks by itself.
    public static func travelTime(to place: OutingPlace, key: String) async -> String? {
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
    public var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Whether this Mac may use its location. It asks only when someone picks
/// "Toon reistijd" from the map's menu.
@MainActor @Observable
public final class LocationAccess: NSObject, CLLocationManagerDelegate {
    public static let shared = LocationAccess()

    private let manager = CLLocationManager()
    public private(set) var status: CLAuthorizationStatus

    override private init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    public var granted: Bool { status == .authorizedAlways || status == .authorized }
    public var undecided: Bool { status == .notDetermined && Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil }

    public func ask() { manager.requestWhenInUseAuthorization() }

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

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.status = status }
    }
}

/// Looks the outing's place up (once, kept on disk) and hands it to `content`.
public struct PlaceReader<Content: View>: View {
    let outing: Outing
    let content: (OutingPlace?, Bool) -> Content
    @State private var lookup: (key: String, place: OutingPlace?)?

    /// `content` gets the place, and whether it is still being looked up.
    public init(outing: Outing, @ViewBuilder content: @escaping (OutingPlace?, Bool) -> Content) {
        self.outing = outing
        self.content = content
    }

    private var place: OutingPlace? {
        OutingMaps.book.cached(outing) ?? (lookup?.key == outing.placeKey ? lookup?.place : nil)
    }

    private var lookingUp: Bool { outing.placeKey != nil && place == nil && lookup?.key != outing.placeKey }

    public var body: some View {
        content(place, lookingUp)
            .task(id: outing.placeKey) {
                guard let key = outing.placeKey, OutingMaps.book.cached(outing) == nil else { return }
                let found = await OutingMaps.book.place(for: outing)
                withAnimation(.easeOut(duration: 0.2)) { lookup = (key, found) }
            }
    }
}

/// A still map of the place with a pin; a click opens it in Kaarten.
public struct MapSnapshot: View {
    let outing: Outing
    let place: OutingPlace
    var dark: Bool
    var pinTint: Color
    @State private var image: NSImage?
    @State private var area = CGSize.zero
    @State private var landed = false

    public init(outing: Outing, place: OutingPlace, dark: Bool, pinTint: Color = .pink) {
        self.outing = outing
        self.place = place
        self.dark = dark
        self.pinTint = pinTint
    }

    private var size: CGSize {
        CGSize(width: (area.width / 40).rounded(.up) * 40, height: (area.height / 20).rounded(.up) * 20)
    }
    private var key: String { OutingMaps.snapshotKey(place, size: size, dark: dark) }
    private var query: String { outing.placeQueries.first ?? outing.title }

    public var body: some View {
        Rectangle().fill(.quaternary.opacity(0.5))
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill().transition(.opacity) }
            }
            .overlay {
                if image != nil {
                    GeometryReader { geo in
                        MapPin(outing: outing, tint: pinTint)
                            .offset(y: landed ? 0 : -26)
                            .opacity(landed ? 1 : 0)
                            .position(x: geo.size.width / 2, y: geo.size.height * OutingMaps.pinHeight - MapPin.tip)
                    }
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { OutingMaps.openPlace(place, query: query) }
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { area = $0 }
            .task(id: key) { await load() }
            .help("Open in Kaarten")
            .accessibilityLabel("Kaart van \(outing.placeLabel(place).title)")
    }

    private func load() async {
        guard area.width > 0, area.height > 0 else { return }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled, let fresh = await OutingMaps.snapshot(place, size: size, dark: dark), !Task.isCancelled else { return }
        let first = image == nil
        withAnimation(.easeOut(duration: 0.25)) { image = fresh }
        if first { withAnimation(.spring(response: 0.45, dampingFraction: 0.62).delay(0.1)) { landed = true } }
    }
}

/// A round head with the outing's picture or its kind, on a short point.
struct MapPin: View {
    let outing: Outing
    var tint: Color
    static let head: CGFloat = 44
    static let point: CGFloat = 10
    static var tip: CGFloat { (head + point - 2) / 2 }

    var body: some View {
        ZStack {
            Ellipse().fill(.black.opacity(0.22)).frame(width: 18, height: 6).blur(radius: 2).offset(y: Self.tip)
            VStack(spacing: -2) {
                OutingPictureReader(outing: outing) { picture in
                    Group {
                        if let picture, CGFloat(picture.width) / CGFloat(max(picture.height, 1)) < 1.5 {
                            Color.clear.overlay { picture.swiftUI.resizable().scaledToFill() }
                        } else {
                            OutingArt(outing: outing, symbolSize: 17)
                        }
                    }
                }
                .frame(width: Self.head - 6, height: Self.head - 6)
                .clipShape(Circle())
                .padding(3)
                .background(Circle().fill(.white))
                Triangle().fill(.white).frame(width: 14, height: Self.point)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.28), radius: 5, y: 3)
        }
        .accessibilityHidden(true)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The travel time from this Mac, when it may know where it is.
public struct TravelTimeReader<Content: View>: View {
    let outing: Outing
    let place: OutingPlace
    let content: (String?) -> Content
    @State private var travel: String?

    public init(outing: Outing, place: OutingPlace, @ViewBuilder content: @escaping (String?) -> Content) {
        self.outing = outing
        self.place = place
        self.content = content
    }

    public var body: some View {
        content(travel)
            .task(id: "\(outing.placeKey ?? "")|\(LocationAccess.shared.granted)") {
                travel = await OutingMaps.travelTime(to: place, key: outing.placeKey ?? outing.title)
            }
    }
}
