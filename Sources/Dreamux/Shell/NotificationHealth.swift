import Foundation

/// Whether banners can actually be delivered.
///
/// This exists because the failure it describes was invisible: the app
/// logged `add()` errors to `os_log` and carried on, so a machine where
/// notifications never worked looked identical to one where nothing had
/// happened yet.
enum NotificationHealth: Equatable {
    case unknown
    case healthy
    case denied
    case failed(String)

    var bannerText: String? {
        switch self {
        case .unknown, .healthy:
            return nil
        case .denied:
            return "Notifications are off. Enable Dreamux in System Settings to get agent alerts."
        case .failed(let reason):
            return "Notifications could not be delivered: \(reason)"
        }
    }
}
