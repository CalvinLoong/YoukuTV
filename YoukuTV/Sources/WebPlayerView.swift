import Foundation
import WebKit

/// 优酷网页播放页地址构造。
///
/// 逆向/实测来源：
/// - H5 搜索接口返回的 `showId` 为 24 位十六进制（如 `9bbc2c96790d11e4b522`）
/// - `list.youku.com/show/id_{showId}.html` 会 302 到真实播放页 `v.youku.com/v_show/id_{vid}.html?s={showId}`
/// - 该页面标题含节目名，实测可正常播放
enum YoukuWebPage {
    /// 优酷剧集详情/播放页
    static func playURL(showId: String) -> URL? {
        URL(string: "https://list.youku.com/show/id_\(showId).html")
    }

    /// 搜索页（用于按关键词跳转）
    static func searchURL(keyword: String) -> URL? {
        var components = URLComponents(string: "https://so.youku.com/search_video")!
        components.queryItems = [
            .init(name: "keyword", value: keyword),
            .init(name: "searchfrom", value: "1")
        ]
        return components.url
    }
}

/// 内嵌网页播放器。
///
/// tvOS 上 WKWebView 支持 HLS 播放，且网页端播放不需要 SecurityGuard 设备指纹，
/// 因此这是当前唯一稳定可用的播放方案。
/// 后续若找到免签名的 H5 播放接口，可在此基础上替换为原生 AVPlayer。
struct WebPlayerView: UIViewRepresentable {
    let url: URL
    /// 播放失败或加载异常时的回调
    var onError: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // 允许全屏播放
        webView.scrollView.isScrollEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Apple TV; CPU like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("https://www.youku.com/", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onError: ((String) -> Void)?

        init(onError: ((String) -> Void)?) {
            self.onError = onError
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError?(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError?(error.localizedDescription)
        }

        /// 播放失败时（常见于会员内容），由页面内的错误提示兜底
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 注入样式，压掉优酷网页顶部的导航条，让内容更适合电视大屏
            let js = """
            (function() {
              var s = document.createElement('style');
              s.type = 'text/css';
              s.innerText = 'body{overflow-x:hidden}' +
                '.y-header,.header,.nav,.y-mplayer-top{display:none !important}';
              document.head.appendChild(s);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
