# YoukuTV for Apple TV

一个 Apple TV（tvOS）客户端，用优酷的公开接口浏览与搜索节目。

> **学习性质的反向工程项目**。代码里的接口协议来自对 CIBN 酷喵影视 TV 客户端
> （`com.cibn.tv` v13.0.1.3）的逆向分析，仅供个人学习与自用测试。
> 请勿用于商业分发或公开传播，勿用于访问付费内容。

---

## 功能

- 首页分类推荐（真实优酷内容）
- 搜索（真实优酷内容）
- 详情页与剧集列表
- 播放器（AVPlayer + HLS）

## 免付费安装路线（不需要 Xcode、不需要开发者账号）

本项目提供 GitHub Actions 工作流，在 GitHub 免费的 macOS runner 上编译出
**未签名** `.ipa`，再用 Sideloadly + 免费 Apple ID 侧载到 Apple TV。

```
推送代码 → GitHub Actions 编译 → 下载 .ipa → Sideloadly 侧载 → Apple TV 上运行
```

### 步骤

**1. Fork 本仓库为公开仓库**
公开仓库的 Actions 分钟数无限且免费；私有仓库只有 2000 分钟/月且需要绑定支付方式。

**2. 触发构建**
Actions 标签页 → `Build tvOS IPA (unsigned)` → `Run workflow` → 等约 10 分钟。

**3. 下载产物**
在运行记录页面底部 Artifacts 下载 `YoukuTV-tvos-ipa`，解压得到 `YoukuTV-unsigned.ipa`。

**4. 侧载到 Apple TV**
1. 电脑安装 [Sideloadly](https://sideloadly.io)（免费，明确支持 Apple TV / tvOS）
2. Apple TV 与电脑连同一 WiFi
3. Apple TV → 设置 → 遥控器与设备 → 远程 App 与设备，记下配对码
4. Sideloadly 拖入 ipa → 选中 Apple TV → 输入**免费 Apple ID** → Start
5. Apple TV → 设置 → 通用 → 隐私与安全性 → App 安装 → 信任开发者

> 免费 Apple ID 的签名有效期 7 天。在 Sideloadly 开启 `Auto-Refresh in Background`
> 可在过期前自动续签。免费账号同时最多侧载 3 个 App。

## 有开发者账号时的本地构建

```bash
cd YoukuTV
xcodegen generate --spec project.yml
open YoukuTV.xcodeproj
```

在 Xcode 中选好 Team 与唯一的 Bundle ID，`Product → Archive` 即可。

## 项目结构

```
YoukuTV/
├── Sources/
│   ├── YoukuTVApp.swift        应用入口
│   ├── ContentView.swift       首页 / 详情页 / 播放页
│   ├── Views.swift             卡片、剧集网格、加载与错误态
│   ├── AppViewModel.swift      状态机与数据调度
│   ├── YoukuWebClient.swift    优酷 H5 数据接口
│   ├── YoukuMTopClient.swift   优酷 mtop 协议客户端（逆向成果）
│   └── PlayerController.swift  AVPlayer 播放控制
├── Tests/                      协议常量回归测试
├── Resources/                  图标、Info.plist
└── project.yml                 XcodeGen 工程配置
```

## 逆向分析要点

详见仓库根目录的 `逆向分析报告.md`。核心结论：

- mtop 网关 `acs.youku.com`，签名 `sign = MD5(token & t & appKey & data)`
- token 来自服务端下发的 Cookie `_m_h5_tk` 前 32 位
- appKey：`23164371`(TV) / `23061772`(OTT) / `23058384`(DVB)
- TV 端播放地址接口依赖 SecurityGuard native 签名，无法纯客户端复现

## 许可

代码部分以 MIT 许可提供。反向分析产物仅用于个人学习研究。
