import Foundation
import CoreLocation
import Combine

/// Weather for the Home widget.
///
/// ## Why Open-Meteo and not WeatherKit
/// WeatherKit is the obvious Apple-native answer and it was rejected for a
/// practical reason: it requires a paid Apple Developer Program membership, a
/// registered App ID with the WeatherKit capability, and a signed build tied to
/// that team. That makes the app un-buildable by anyone who clones the repo,
/// which is a poor trade for one widget. WeatherKit also has a request quota
/// beyond which it bills.
///
/// Open-Meteo needs no key, no account, and no attribution beyond a link. The
/// tradeoff is that it is a third-party service, so:
///   * It is only ever contacted while the Home tab is **open**.
///   * Coordinates are **rounded to 2 decimal places** (~1.1km) before being
///     sent. Precise coordinates are not needed for a temperature reading, and
///     rounding them means the request cannot be used to locate a user's home
///     to street level.
///   * Nothing else about the user is transmitted -- no identifier, no
///     user-agent beyond the system default.
///
/// Location itself comes from CoreLocation only if the user grants it; otherwise
/// the widget shows a "set a location" affordance and the user types a city.
@MainActor
final class WeatherService: NSObject, ObservableObject {
    static let shared = WeatherService()

    struct Reading: Equatable {
        var temperature: Double
        var apparent: Double
        var code: Int
        var isDay: Bool
        var high: Double
        var low: Double
        var place: String
        var fetchedAt: Date
    }

    enum Status: Equatable {
        case idle, locating, loading, ready(Reading), failed(String), needsLocation
    }

    @Published private(set) var status: Status = .idle

    private let manager = CLLocationManager()
    private var task: Task<Void, Never>?
    /// Weather does not change in 30 seconds. Re-opening the Home tab repeatedly
    /// must not re-hit the network each time.
    private static let cacheLifetime: TimeInterval = 15 * 60

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Called from the widget's `.onAppear`. No timer, no background refresh:
    /// the data is fetched when someone is looking at it and not otherwise.
    func refreshIfStale() {
        if case .ready(let reading) = status,
           Date().timeIntervalSince(reading.fetchedAt) < Self.cacheLifetime { return }
        if case .loading = status { return }

        let settings = Settings.shared.data
        guard let latitude = settings.weatherLatitude,
              let longitude = settings.weatherLongitude else {
            requestLocation()
            return
        }
        fetch(lat: latitude, lon: longitude, place: settings.weatherPlaceName)
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            status = .locating
            manager.requestLocation()
        default:
            status = .needsLocation
        }
    }

    func setManualLocation(lat: Double, lon: Double, name: String) {
        Settings.shared.data.weatherLatitude = lat
        Settings.shared.data.weatherLongitude = lon
        Settings.shared.data.weatherPlaceName = name
        fetch(lat: lat, lon: lon, place: name)
    }

    // MARK: - Fetch

    private func fetch(lat: Double, lon: Double, place: String) {
        task?.cancel()
        status = .loading

        // Round before the coordinate ever leaves the process.
        let roundedLat = (lat * 100).rounded() / 100
        let roundedLon = (lon * 100).rounded() / 100
        let unit = Settings.shared.data.weatherUseCelsius ? "celsius" : "fahrenheit"

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(roundedLat)),
            .init(name: "longitude", value: String(roundedLon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "temperature_unit", value: unit),
            .init(name: "timezone", value: "auto"),
            .init(name: "forecast_days", value: "1")
        ]
        guard let url = components.url else { return }

        task = Task { [weak self] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.status = .ready(Reading(
                        temperature: decoded.current.temperature_2m,
                        apparent: decoded.current.apparent_temperature,
                        code: decoded.current.weather_code,
                        isDay: decoded.current.is_day == 1,
                        high: decoded.daily.temperature_2m_max.first ?? 0,
                        low: decoded.daily.temperature_2m_min.first ?? 0,
                        place: place.isEmpty ? "Current location" : place,
                        fetchedAt: Date()))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.status = .failed("Couldn't reach weather service") }
            }
        }
    }

    // MARK: - WMO weather codes

    /// Open-Meteo returns WMO codes; map them to SF Symbols. Grouped rather than
    /// exhaustive because the distinction between "slight" and "moderate"
    /// drizzle does not change which icon a person wants to see.
    static func symbol(for code: Int, isDay: Bool) -> String {
        switch code {
        case 0:        return isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2:     return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3:        return "cloud.fill"
        case 45, 48:   return "cloud.fog.fill"
        case 51...57:  return "cloud.drizzle.fill"
        case 61...67:  return "cloud.rain.fill"
        case 71...77:  return "cloud.snow.fill"
        case 80...82:  return "cloud.heavyrain.fill"
        case 85, 86:   return "cloud.snow.fill"
        case 95...99:  return "cloud.bolt.rain.fill"
        default:       return "cloud.fill"
        }
    }

    static func describe(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1, 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67: return "Rain"
        case 71...77: return "Snow"
        case 80...82: return "Showers"
        case 85, 86: return "Snow showers"
        case 95...99: return "Thunderstorm"
        default: return "—"
        }
    }

    private struct OpenMeteoResponse: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double
            let weather_code: Int
            let is_day: Int
        }
        struct Daily: Decodable {
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }
}

extension WeatherService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            let coordinate = location.coordinate
            // Reverse-geocode only for a display name; the name never leaves the
            // device and is not sent to the weather API.
            let name = (try? await CLGeocoder().reverseGeocodeLocation(location).first?.locality) ?? nil
            Settings.shared.data.weatherLatitude = coordinate.latitude
            Settings.shared.data.weatherLongitude = coordinate.longitude
            Settings.shared.data.weatherPlaceName = name ?? ""
            self.fetch(lat: coordinate.latitude, lon: coordinate.longitude, place: name ?? "")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = .needsLocation }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorized, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: self.status = .needsLocation
            default: break
            }
        }
    }
}
