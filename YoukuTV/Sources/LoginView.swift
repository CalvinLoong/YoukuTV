import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 顶部导航栏的账号按钮。
///
/// 未登录时显示「登录」，已登录时显示昵称。
struct AccountButton: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        Button {
            if model.isLoggedIn {
                model.logout()
            } else {
                model.presentLogin()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    .font(.system(size: 18))
                Text(model.isLoggedIn
                     ? (model.credentials?.nickname.isEmpty == false
                        ? model.credentials!.nickname
                        : "已登录")
                     : "登录")
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(model.isLoggedIn ? Palette.accent : Palette.secondaryText)
        }
        .buttonStyle(.plain)
    }
}

/// 扫码登录面板。
///
/// 流程：
/// 1. 调优酷 Havana 接口生成二维码（返回短链 URL）
/// 2. 本地用 CoreImage 把 URL 渲染成二维码图，用户用手机优酷 App 扫
/// 3. 每 3 秒轮询登录状态
/// 4. 成功后写入凭据，会员内容随即解锁
struct LoginSheet: View {
    @ObservedObject var model: AppViewModel

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 26) {
                Text("登录优酷账号")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Palette.primaryText)

                switch model.loginStage {
                case .idle, .preparing:
                    ProgressView()
                        .controlSize(.large)
                    Text("正在获取二维码…")
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.secondaryText)

                case .waitingScan(let qrText):
                    if !qrText.isEmpty {
                        QRCodeImage(text: qrText)
                            .frame(width: 300, height: 300)
                            .padding(18)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text("请用手机上的优酷 App 扫描二维码")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Palette.primaryText)
                    Text("扫描后请在手机上确认登录")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.tertiaryText)

                case .scanned:
                    ProgressView().controlSize(.large)
                    Text("已扫码，请在手机上确认")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Palette.accent)

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Palette.accent)
                    Text("登录成功")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Palette.primaryText)

                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(Palette.accentWarm)
                    Text(message)
                        .font(.system(size: 17))
                        .foregroundStyle(Palette.primaryText)
                    Button("重新获取二维码") {
                        Task { await model.startQRLogin() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                }

                Spacer()

                Button("返回") {
                    model.dismissLogin()
                }
                .font(.system(size: 16))
                .foregroundStyle(Palette.secondaryText)
                .padding(.bottom, 30)
            }
            .padding(.top, 50)
        }
        .task {
            if model.loginStage == .preparing {
                await model.startQRLogin()
            }
        }
    }
}

/// 用 CoreImage 把一段文本渲染成二维码。
///
/// tvOS 没有浏览器可用，但 CoreImage 自带二维码生成器（CIFilter.qrCodeGenerator），
/// 不依赖任何第三方库。
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = QRCodeImage.generate(text) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Color.white
        }
    }

    /// 生成二维码位图。
    ///
    /// CIContext 较重，缓存起来复用，避免每次 SwiftUI 刷新都重建。
    private static let context = CIContext()

    static func generate(_ text: String) -> UIImage? {
        guard !text.isEmpty,
              let data = text.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        // 容错等级 M，兼顾容量与容错
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }

        // 把 CIImage 放大到清晰可扫的尺寸（每模块 12 像素）
        let scale = CGAffineTransform(scaleX: 12, y: 12)
        let scaled = output.transformed(by: scale)

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
