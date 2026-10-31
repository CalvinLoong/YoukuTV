import Foundation

/// 登录联调工具 —— 用真实账号跑通扫码登录全链路。
///
/// ## 为什么需要它
///
/// App 侧的登录 UI（LoginView.swift）如果失败，可能是两类完全不同的原因：
///   a) 协议实现错了（tokenInfo 字段不对、method 不对……）
///   b) UI 有 bug（二维码没渲染出来、焦点不对、sheet 弹不出来）
///
/// 在电视上没法看日志、没法断点，区分成本极高。
/// 这个工具在 Mac 上跑，**用的是同一份 YoukuLoginClient.swift 源码**，
/// 所以：
///   · 协议问题 → 这里就会失败，可以直接改协议代码
///   · 这里成功 → 说明协议 OK，问题一定在 UI 层
///
/// ## 用法
///
///     ./build/youku-login-probe [输出目录]
///
/// 流程：
///   1. 调 genQrCode 拿二维码 URL + 轮询 token
///   2. 用 CoreImage 渲染成 PNG（和 App 里同一个滤镜）
///   3. 打印 PNG 路径与二维码内容
///   4. 循环轮询，打印 14030 / 14031 / 3000 状态变化
///   5. 成功后把凭据写成 JSON，交给 tools/校验凭据.py 复验
///
/// ## 超时
///
/// 默认等 5 分钟。二维码是短时效的，超时了就重新跑一次。

// MARK: - 入口

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath + "/build/登录联调"

let fm = FileManager.default
try? fm.createDirectory(
    atPath: outputDir,
    withIntermediateDirectories: true
)

let qrPath = "\(outputDir)/登录二维码.png"
let credPath = "\(outputDir)/凭据.json"

print("=== 优酷扫码登录联调 ===")
print("输出目录：\(outputDir)")
print("")

let client = YoukuLoginClient()

// MARK: - 1. 生成二维码

print("[1/3] 调 genQrCode …")
let qr: YoukuLoginClient.QRCode
do {
    qr = try await client.generateQRCode()
} catch {
    print("✗ 生成二维码失败：\(error.localizedDescription)")
    exit(1)
}

print("✓ 二维码内容：\(qr.url)")
print("  轮询 token：\(qr.pollToken)")
print("  建议间隔：\(qr.pollMilliseconds) ms")
print("")

// MARK: - 2. 渲染 PNG

print("[2/3] 渲染二维码 PNG …")
do {
    try QRWriter.write(content: qr.url, to: qrPath)
    print("✓ 已生成：\(qrPath)")
} catch {
    print("✗ 渲染失败：\(error.localizedDescription)")
    exit(1)
}
print("")
print("  ────────────────────────────────────────")
print("   请用手机「优酷」App 扫描这个二维码")
print("   扫码后确认登录，然后回到这里看结果")
print("  ────────────────────────────────────────")
print("")

// MARK: - 3. 轮询

print("[3/3] 开始轮询登录状态 …")
let deadline = Date().addingTimeInterval(300)
var lastStage = ""
var attempts = 0

while Date() < deadline {
    attempts += 1
    do {
        let result = try await client.pollLogin(token: qr.pollToken)
        switch result {
        case .waiting:
            if lastStage != "waiting" {
                print("  [\(attempts)] 14030 等待扫码 …")
                lastStage = "waiting"
            }
        case .scanned:
            if lastStage != "scanned" {
                print("  [\(attempts)] 14031 已扫码，请在手机上确认 …")
                lastStage = "scanned"
            }
        case .success(let credentials):
            print("")
            print("✓ 3000 登录成功！")
            print("")
            print("  昵称：\(credentials.nickname.isEmpty ? "(空)" : credentials.nickname)")
            print("  ytid：\(credentials.ytid)")
            print("  ptoken：\(credentials.ptoken.prefix(12))… (\(credentials.ptoken.count) 字符)")
            print("  yktk：\(credentials.yktk.prefix(12))… (\(credentials.yktk.count) 字符)")
            print("  loginAppId：\(credentials.loginAppId)")
            print("  有效期至：\(credentials.cookieExpireTime)")
            print("  凭据有效：\(credentials.isValid ? "是" : "否 ❌")")
            print("")

            // 落盘，供 tools/校验凭据.py 与 App 侧比对
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(credentials) {
                try data.write(to: URL(fileURLWithPath: credPath))
                print("  凭据已保存：\(credPath)")
            }

            // ★ 原始 returnValue dump —— 凭据解析失败时用它对照真实结构
            if let raw = await client.lastRawReturnValue() {
                let rawPath = "\(outputDir)/returnValue.json"
                let rawData = try JSONSerialization.data(
                    withJSONObject: raw,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                try rawData.write(to: URL(fileURLWithPath: rawPath))
                print("  原始 returnValue：\(rawPath)")
            }

            if !credentials.isValid {
                print("")
                print("⚠️ 登录成功但凭据解析为空 —— 请把 returnValue.json 发给开发")
            }
            exit(0)
        }
    } catch {
        print("  [\(attempts)] 轮询出错：\(error.localizedDescription)")
        print("         \(error)")
        // 单次失败不退出，继续重试（网络抖动）
    }

    let interval = max(1.0, Double(qr.pollMilliseconds) / 1000.0)
    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
}

print("")
print("✗ 超时（5 分钟）未完成登录。二维码可能已失效，重新运行一次。")
exit(2)
