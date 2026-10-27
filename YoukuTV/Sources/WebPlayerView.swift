import Foundation
import WebKit
import AVFoundation

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

/// 从网页播放页中提取原生播放地址的桥接器。
///
/// 背景（逆向结论）：
/// 优酷播放地址接口 `ups.youku.com/ups/get.json` 需要 `ckey`（防盗链），
/// 而 ckey 由阿里 AWSC（Web SecurityGuard）在**浏览器环境**中根据设备指纹算出，
/// 无法用纯 Swift 复现。服务端下发的 `defaultCkey` 是加密态（base64 套 base64
/// 解出来仍是二进制密文），必须由 AWSC 自己解密。
///
/// 本桥接器不试图复现算法，而是借用网页播放页自己的运行环境：
/// 1. WKWebView 加载播放页，页面内部自行完成 AWSC 计算并发起 ups 请求
/// 2. 注入 JS 捕获 ups 响应（**三种传输方式都要覆盖**，实测见下）
/// 3. 从响应中递归提取 m3u8 地址
/// 4. 交回 Swift，交给原生 AVPlayer 播放
///
/// 加密逻辑完全留在网页内部，App 不触碰任何密钥。
///
/// 若提取失败（页面结构变化等），自动回退到让网页自行播放。
enum PlaybackBridge {
    /// 注入到页面的钩子脚本。
    ///
    /// 抓取方式（按实测可靠性排序）：
    ///
    /// 1. **PerformanceObserver + resource timing**（主力，已实测可靠）
    ///    ups 响应 `mtop.youku.play.ups.appinfo.get` 解析后，
    ///    播放器会请求 `https://pl-ali.youku.com/playlist/m3u8?vid=...&type=flv&...`，
    ///    这个请求会进入 Resource Timing。
    ///
    ///    ⚠️ 匹配要点：地址形如 `playlist/m3u8?vid=...`，
    ///    **`m3u8` 后面还带查询参数**，所以不能用 `endsWith('.m3u8')` 判断，
    ///    必须用 `indexOf('m3u8')`。
    ///
    /// 2. **XHR / fetch 挂钩**（补充）
    ///    若 mtop 走 XHR 或 fetch，直接截获响应体。
    ///
    /// 3. **JSONP 解析**（补充）
    ///    ups 响应实测为 JSONP 包装 `mtopjsonp1({...})`，
    ///    若能截到需先剥离包装再解析。
    ///    注意：播放器是 ES module，回调在闭包内且不是 window 属性，
    ///    无法通过拦截全局函数来捕获 JSONP —— 这也是主方案选 Resource Timing 的原因。
    static let hookScript = """
    (function() {
      if (window.__ykPlaybackHookInstalled) { return; }
      window.__ykPlaybackHookInstalled = true;
      window.__ykFound = [];

      // 判断是否播放地址。
      // 实测播放地址形态: https://pl-ali.youku.com/playlist/m3u8?vid=...&type=flv&...
      // 注意 m3u8 后带查询参数，不能用 endsWith('.m3u8')；
      // 同时要排除统计/日志类 URL（它们只是参数里含 "m3u8" 字样），
      // 因此要求路径段本身就是 m3u8。
      function isPlayUrl(u) {
        if (!u) { return false; }
        var s = String(u);
        if (s.indexOf('http') !== 0) { return false; }
        // 去掉查询串后，路径必须以 /m3u8 结尾
        var path = s.split('?')[0].split('#')[0];
        if (path.slice(-5) !== '/m3u8') { return false; }
        // 排除统计与日志域名
        if (s.indexOf('mmstat.com') !== -1) { return false; }
        if (s.indexOf('yk-ssp.ad.youku.com') !== -1) { return false; }
        return true;
      }

      function deliver(urls) {
        if (!urls || !urls.length) { return; }
        var uniq = [];
        for (var i = 0; i < urls.length; i++) {
          if (uniq.indexOf(urls[i]) === -1) { uniq.push(urls[i]); }
        }
        if (!uniq.length) { return; }
        window.__ykFound = uniq;
        try {
          window.webkit.messageHandlers.ykPlayback.postMessage(
            JSON.stringify({ urls: uniq })
          );
        } catch (e) {}
      }

      // ---- 主方案：PerformanceObserver 监控资源加载 ----
      function scanResourceTiming() {
        try {
          var hits = [];
          var entries = performance.getEntriesByType('resource');
          for (var i = 0; i < entries.length; i++) {
            var n = entries[i].name || '';
            if (isPlayUrl(n)) { hits.push(n); }
          }
          if (hits.length) { deliver(hits); }
        } catch (e) {}
      }

      try {
        var po = new PerformanceObserver(function(list) {
          var hits = [];
          list.getEntries().forEach(function(e) {
            var n = e.name || '';
            if (isPlayUrl(n)) { hits.push(n); }
          });
          if (hits.length) { deliver(hits); }
        });
        po.observe({ entryTypes: ['resource'] });
        window.__ykPerfObserver = po;
      } catch (e) {}

      // ---- 兜底 1：定时扫 Resource Timing ----
      try {
        setInterval(scanResourceTiming, 1200);
      } catch (e) {}

      // ---- 兜底 2：扫描页面内联 script（JSONP 执行后内容留在 script 节点里）----
      function scanInlineScripts() {
        try {
          var hits = [];
          var scripts = document.querySelectorAll('script');
          for (var i = 0; i < scripts.length; i++) {
            var t = scripts[i].textContent || '';
            if (t && t.indexOf('m3u8') !== -1) {
              var re = /["']([^"']*m3u8[^"']*)["']/g;
              var m;
              while ((m = re.exec(t)) !== null) {
                if (isPlayUrl(m[1])) { hits.push(m[1]); }
              }
            }
          }
          if (hits.length) { deliver(hits); }
        } catch (e) {}
      }

      try {
        setInterval(scanInlineScripts, 1500);
      } catch (e) {}

      // ---- 兜底 3：播放事件触发时立即扫一遍 ----
      try {
        document.addEventListener('play', function() {
          scanResourceTiming();
          scanInlineScripts();
        }, true);
      } catch (e) {}

      // ---- 兜底 4：主动触发播放 ----
      // 优酷播放页会先播广告，广告结束后才请求正片地址。
      // 这里定期尝试点击页面上的「跳过广告 / 播放」按钮，
      // 让正片的 ups 请求尽早发出，缩短拿到播放地址的等待时间。
      var PLAY_SELECTORS = [
        '.y-player-skip-ad',
        '[class*="skip"]',
        '[class*="Skip"]',
        '.btn-skip',
        '.skip-btn',
        '.video-play',
        '.y-player-video .play-icon',
        '[class*="playIcon"]',
        '[class*="play-btn"]',
        '.y-player-play-icon'
      ];

      function tryTriggerPlay() {
        for (var i = 0; i < PLAY_SELECTORS.length; i++) {
          try {
            var el = document.querySelector(PLAY_SELECTORS[i]);
            if (el) {
              el.click();
              // 点击后延迟再扫一次
              setTimeout(function() {
                scanResourceTiming();
                scanInlineScripts();
              }, 800);
              return true;
            }
          } catch (e) {}
        }
        return false;
      }

      try {
        // 页面加载后先等广告播几秒，再尝试触发
        setTimeout(tryTriggerPlay, 3000);
        setInterval(tryTriggerPlay, 5000);
      } catch (e) {}

      // ---- 补充：XHR / fetch 响应体 ----
      function report(text) {
        try {
          if (!text) { return; }
          var t = String(text).trim();
          // 剥离 JSONP 包装: mtopjsonp1({...})
          var m = t.match(/^[A-Za-z_$][\\w$]*\\s*\\(([\\s\\S]*)\\)\\s*;?$/);
          if (m) { t = m[1]; }
          var obj;
          try { obj = JSON.parse(t); } catch (e) { return; }

          var urls = [];
          (function collect(o) {
            if (!o || typeof o !== 'object') { return; }
            if (Object.prototype.toString.call(o) === '[object Array]') {
              for (var i = 0; i < o.length; i++) { collect(o[i]); }
              return;
            }
            for (var key in o) {
              var v = o[key];
              if (typeof v === 'string') {
                if (v.indexOf('m3u8') !== -1) { urls.push(v); }
              } else if (v && typeof v === 'object') {
                collect(v);
              }
            }
          })(obj);

          if (urls.length) { deliver(urls); }
        } catch (e) {}
      }

      function isUpsUrl(url) {
        if (!url) { return false; }
        var u = String(url);
        return u.indexOf('ups') !== -1 &&
               (u.indexOf('appinfo') !== -1 || u.indexOf('get.json') !== -1);
      }

      var origOpen = XMLHttpRequest.prototype.open;
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        try { this.__ykUrl = url; } catch (e) {}
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        try {
          var s = this;
          if (isUpsUrl(this.__ykUrl)) {
            this.addEventListener('load', function() {
              try { report(s.responseText); } catch (e) {}
            });
          }
        } catch (e) {}
        return origSend.apply(this, arguments);
      };

      if (typeof window.fetch === 'function') {
        var origFetch = window.fetch;
        window.fetch = function(input, init) {
          var url = (typeof input === 'string') ? input : (input && input.url);
          var p = origFetch.apply(this, arguments);
          if (isUpsUrl(url)) {
            p.then(function(resp) {
              try {
                resp.clone().text().then(function(t) { report(t); });
              } catch (e) {}
            }).catch(function() {});
          }
          return p;
        };
      }
    })();
    """

    /// 脚本消息名（需与 hookScript 中的 messageHandlers 名称一致）
    static let messageName = "ykPlayback"
}

/// 内嵌网页播放器。
///
/// 双模式：
/// - `.bridge`：注入钩子拦截 m3u8，交给原生 AVPlayer 播放（体验最好）
/// - `.inline`：网页自行播放（兜底，兼容性最好）
struct WebPlayerView: UIViewRepresentable {
    enum Mode {
        /// 拦截播放地址，转原生播放器
        case bridge
        /// 网页内直接播放
        case inline
    }

    let url: URL
    var mode: Mode = .inline
    /// 拦截到播放地址时的回调
    var onExtracted: ((URL) -> Void)?
    /// 页面加载完成的回调
    var onLoaded: (() -> Void)?
    /// 加载失败回调
    var onError: ((String) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        if mode == .bridge {
            // 注入钩子脚本
            config.userContentController.addUserScript(
                WKUserScript(
                    source: PlaybackBridge.hookScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
            )
            // 注册消息处理器
            config.userContentController.add(
                context.coordinator,
                name: PlaybackBridge.messageName
            )
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
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
        Coordinator(mode: mode, onExtracted: onExtracted, onLoaded: onLoaded, onError: onError)
    }

    /// 判断一个 URL 是否为优酷播放地址。
    ///
    /// 路径段必须以 `/m3u8` 结尾（去掉查询串后），
    /// 并排除统计/日志类域名。
    static func isPlayURL(_ raw: String) -> Bool {
        guard raw.hasPrefix("http") else { return false }
        let path = raw.split(separator: "?", maxSplits: 1).first.map(String.init) ?? raw
        guard path.hasSuffix("/m3u8") else { return false }
        if raw.contains("mmstat.com") { return false }
        if raw.contains("yk-ssp.ad.youku.com") { return false }
        return true
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let mode: Mode
        private let onExtracted: ((URL) -> Void)?
        private let onLoaded: (() -> Void)?
        private let onError: ((String) -> Void)?
        private var delivered = false

        init(
            mode: Mode,
            onExtracted: ((URL) -> Void)?,
            onLoaded: (() -> Void)?,
            onError: ((String) -> Void)?
        ) {
            self.mode = mode
            self.onExtracted = onExtracted
            self.onLoaded = onLoaded
            self.onError = onError
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard !delivered,
                  message.name == PlaybackBridge.messageName,
                  let payload = message.body as? String,
                  let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let urls = obj["urls"] as? [String]
            else { return }

            // 播放地址形如 playlist/m3u8?vid=...（m3u8 后带查询参数）
            guard let candidate = urls.first(where: { WebPlayerView.isPlayURL($0) }),
                  let url = URL(string: candidate)
            else { return }

            delivered = true
            DispatchQueue.main.async { [onExtracted] in
                onExtracted?(url)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError?(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError?(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoaded?()
            // 注入样式，压掉网页顶部导航条，让内容更适合电视大屏
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
