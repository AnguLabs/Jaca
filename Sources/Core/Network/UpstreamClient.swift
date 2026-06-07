import Foundation

/// Performs the proxy's outbound request via URLSession. Redirects are NOT
/// followed (the client re-requests through the proxy, so we capture each hop),
/// and per-task metrics give us time-to-first-byte.
final class UpstreamClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Response: Sendable {
        var statusCode: Int
        var headers: [(String, String)]
        var body: Data
        var responseStart: Date?
        var responseEnd: Date?
        var error: String?
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var metricsByTask: [Int: URLSessionTaskMetrics] = [:]

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldUsePipelining = false
        config.connectionProxyDictionary = [:]   // go direct; never recurse through a system proxy
        config.timeoutIntervalForRequest = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func send(_ request: URLRequest) async -> Response {
        await withCheckedContinuation { continuation in
            var taskRef: URLSessionDataTask?
            let task = session.dataTask(with: request) { [weak self] data, response, error in
                let id = taskRef?.taskIdentifier ?? -1
                let metrics = self?.popMetrics(id)
                let txnMetric = metrics?.transactionMetrics.last
                if let error {
                    continuation.resume(returning: Response(
                        statusCode: 0, headers: [], body: Data(),
                        responseStart: txnMetric?.responseStartDate,
                        responseEnd: txnMetric?.responseEndDate ?? Date(),
                        error: error.localizedDescription
                    ))
                    return
                }
                let http = response as? HTTPURLResponse
                let headers: [(String, String)] = (http?.allHeaderFields ?? [:]).compactMap { key, value in
                    guard let k = key as? String else { return nil }
                    return (k, "\(value)")
                }
                continuation.resume(returning: Response(
                    statusCode: http?.statusCode ?? 0,
                    headers: headers,
                    body: data ?? Data(),
                    responseStart: txnMetric?.responseStartDate,
                    responseEnd: txnMetric?.responseEndDate ?? Date(),
                    error: nil
                ))
            }
            taskRef = task
            task.resume()
        }
    }

    private func popMetrics(_ id: Int) -> URLSessionTaskMetrics? {
        lock.lock(); defer { lock.unlock() }
        return metricsByTask.removeValue(forKey: id)
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)  // capture the 3xx; let the client re-request through us
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock(); metricsByTask[task.taskIdentifier] = metrics; lock.unlock()
    }
}
