# Youku TV for Apple TV — 项目总览

## 一句话

对优酷喵 TV 客户端做逆向工程，做出能在 Apple TV 上跑的应用，
**并且用零成本路线（不需要 Xcode、不需要 99 美元开发者账号）就能装到你的 Apple TV 上**。

---

## 两个核心问题，两个解法

| 你的顾虑 | 解法 | 成本 |
|---|---|---|
| 电脑空间不够（只剩 20GB，Xcode 要 35GB+） | 编译搬到 **GitHub 免费云端 Mac**，本机啥也不用装 | 0 |
| 开发者账号 99 美元太贵 | 用 **免费 Apple ID + Sideloadly 侧载**，完全绕开付费账号 | 0 |

```
你的代码 → GitHub 云端编译 → YoukuTV.ipa → Sideloadly 免费签名 → 你的 Apple TV
```

- 公开仓库的 Actions 分钟数**无限免费**
- Sideloadly 明确支持 Apple TV，免费 Apple ID 即可（签名 7 天有效，可后台自动续签）

---

## 成果清单

### 1. 逆向分析（完成，有证据链）

官方 APK（23.8MB / 7 dex / 33 so）→ 23,224 个反编译源文件 → 提取出：

- **mtop 协议全貌**：网关、appKey 家族、20+ 请求头、MD5 签名算法、token 下发机制
- **30+ 内容/播放 API 目录**：含参数名、版本号、调用点
- **播放参数协议**：`biz_params` / `ad_params` / `steal_params` 完整字段清单
- **清晰度标识体系**：`sys_4k` / `sys_1080p_h265` 等

→ `逆向分析报告.md`

### 2. 已验证可用的数据通道

优酷 H5 接口 `search.youku.com/api/search` 免设备指纹签名，
实测「三体」8 条、「庆余年」8 条、「动物世界」51 条真实剧集返回。

### 3. tvOS 应用工程

9 个 Swift 源文件 / 2,403 行。
**已在 GitHub 云端真实编译通过**（Xcode 26.3 / tvOS SDK 26.2 /
arm64-apple-tvos16.0），零错误零警告。

### 4. 云端编译工作流（已跑通）

`.github/workflows/build-tvos-ipa.yml` — 三段式：

```
plan (ubuntu)  → build (Intel × 2 并行)  → finalize (ubuntu，收敛产物)
```

实测：从触发到产出 ipa **约 10 分钟**（其中编译 1-2 分钟），
产物 `YoukuTV-tvos-ipa`（约 230KB）。

**关键点：默认走 Intel 构建机池**（`macos-15-intel` / `macos-26-intel`）。
GitHub 的 macOS runner 分 arm64 与 intel 两个独立供给池，
arm64 池官方公告过 capacity constraints（实测排队 15 分钟拿不到机器），
Intel 池实测秒级拿到。详见 `逆向分析报告.md` 第 13 章。

### 5. 安装包已发布

<https://github.com/CalvinLoong/YoukuTV/releases> — v1.0.0，
`YoukuTV-unsigned.ipa`（230KB / arm64 / tvOS 16.0+）。

---

## 功能状态

| 能力 | 状态 |
|---|---|
| 首页分类推荐 | ✅ 真实优酷内容 |
| 搜索 | ✅ 真实优酷内容 |
| 详情页 / 剧集列表 | ✅ 界面完成 |
| 视频播放 | ✅ 已实现（ups 接口直取 + 多清晰度） |

**播放链路**：全程只走 JSON 接口，不访问任何网页。

```
搜索  search.youku.com/api/search   → vid + 权益标签 + 集数
      ↓
地址  un-acs.youku.com ups          → m3u8（含主播放列表 → 自动码率）
      ↓
播放  AVPlayer（原生，支持多清晰度切换）
```

- `YoukuWebClient` — 搜索接口（JSON，不受风控影响）
- `YoukuUpsClient` — mtop md5 签名 + ups 接口，解析 JSONP 响应
- 内置凭据（ckey + utid）— 实测**不绑定 vid**，一组凭据可播任意视频，有效期 > 2 天
- `YoukuEpisodeClient` — 选集列表（**可选补充**，走 HTML 页面，可能被优酷风控；
  拿不到也不影响播放）

**两个关键的平台约束**（都实测确认）：
1. tvOS **没有 WebKit**（Apple 官方：tvOS has no WKWebView at all），
   所以「内嵌网页播放器」这条路不存在
2. 优酷对 **HTML 页面有阿里 x5 风控**（返回验证码页，真实浏览器同样被拦），
   而 tvOS 无 JS 引擎无法过验证码 → 播放链路必须完全避开 HTML

**权益边界**：VIP/付费内容接口返回 SUCCESS 但不给地址，
本项目**有意不做**会员校验绕过，App 会明确提示原因。

**凭据失效怎么办**：双击 `更新ckey.command` 重新生成（约 1 分钟），
或跑 `tools/校验凭据.py` 检查当前是否还有效。

---

## 现在你要做的（5 分钟）

1. 打开 <https://github.com/CalvinLoong/YoukuTV/releases>
   → 展开 v1.0.0 → 下载 `YoukuTV-unsigned.ipa`
2. 电脑装 [Sideloadly](https://sideloadly.io)（免费，支持 Apple TV）
3. Apple TV 和电脑连同一 WiFi
4. Apple TV → 设置 → 遥控器与设备 → 远程 App 与设备 → 记下配对码
5. Sideloadly 拖入 ipa → 选 Apple TV → 填免费 Apple ID → Start
6. Apple TV → 设置 → 通用 → 隐私与安全性 → App 安装 → 信任开发者

**或者直接双击 `安装到AppleTV.command`**，脚本会自动检查安装包、
引导你走完整个流程。

→ 详见 `零成本安装指南.md`

---

## 磁盘问题其实不用管

编译在云端做，本机不需要 Xcode，所以**不用为它清 35GB 空间**。

如果你还想清理（微信 26GB 是大头），我准备了两个双击即用的脚本：
- `清理缓存.command` — 通用缓存，约 5-7GB
- `清理应用缓存.command` — 腾讯文档/飞书/豆包/WPS，约 8-12GB

微信的 26GB 需要在微信 App 内清（设置 → 通用 → 存储空间），
直接删文件夹会损坏数据。详见 `磁盘清理方案.md`。

**建议**：先按零成本路线跑一遍，确认能用再决定要不要清磁盘。

---

## 文件索引

```
YoukuTV/                          应用工程
├── Sources/                      9 个 Swift 源文件
├── Tests/                        协议常量回归测试
├── Resources/                    图标 / Info.plist
├── project.yml                   XcodeGen 配置
└── 交付说明.md                    有开发者账号时的完整流程

.github/workflows/                云端编译工作流
安装到AppleTV.command             ← 双击就能装（推荐）
零成本安装指南.md                   ← 详细图文步骤
逆向分析报告.md                    技术细节（含第 13 章云编译实战）
输出/YoukuTV-unsigned.ipa          已编译好的安装包
overview.md                       本文件
磁盘清理方案.md                    清理指引
清理缓存.command / 清理应用缓存.command
tools/                            自研校验脚本（编译/凭据/链路）
```

---

## 法律提示

代码里的协议来自对 CIBN 酷喵影视 TV 客户端（`com.cibn.tv` v13.0.1.3）的逆向分析，
属学习性质，仅供个人自用测试。请勿用于商业分发或公开传播，勿用于访问付费内容。
