import UIKit

/// Leaves a trace in the server's access log (`/help/api/health?app=…`) so that
/// what happens on the iPhone in the background can be checked from the server:
/// a step name, an error code and the app build, nothing personal.
enum Diagnostics {
    static func note(_ event: String) {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "fg"
        case .inactive: state = "inactive"
        default: state = "bg"
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = WebViewController.host
        components.path = "/help/api/health"
        components.queryItems = [
            URLQueryItem(name: "app", value: event),
            URLQueryItem(name: "b", value: Bridge.build),
            URLQueryItem(name: "s", value: state),
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpShouldHandleCookies = false
        URLSession.shared.dataTask(with: request).resume()
    }

    /// "domain-code" of an error, e.g. "callkit-1".
    static func code(_ error: Error) -> String {
        let error = error as NSError
        let domain = error.domain.components(separatedBy: ".").last ?? error.domain
        return "\(domain)-\(error.code)"
    }
}
