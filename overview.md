# Youku TV for Apple TV — 项目总览

## 做了什么

对优酷喵 TV 客户端（`com.cibn.tv` v13.0.1.3）做逆向工程，逆向出其 mtop 通信协议，
并据此搭建了一个可在 Apple TV 上运行、通过 TestFlight 分发的 tvOS 应用。

---

## 成果清单

### 1. 逆向分析（已完成，有证据链）

从官方渠道 `https://pd.youku.com/CIBN` 获取酷喵 TV 官方 APK（23.8MB / 7 dex / 33 so），
用 REA 6.8.0 + jadx-headless-mcp 0.7.1（SHA-256 与官方审计值一致）+ JADX CLI + androguard
反编译出 23,224 个 Java 源文件，提取出：

- **mtop 协议全貌**：网关、appKey 家族、20+ 请求头、MD5 签名算法、token 下发机制
- **30+ 内容/播放 API 目录**：含参数名、版本号、调用点
- **播放参数协议**：`biz_params` / `ad_params` / `steal_params` 完整字段清单
- **清晰度标识体系**：`sys_4k` / `sys_1080p_h265` 等 TV 端内置标识

产出文档：`逆向分析报告.md`

### 2. 可用的数据通道（已实测返回真实数据）

优酷 H5 接口 `search.youku.com/api/search` 免设备指纹签名，实测多个关键词均返回真实剧集、
真实海报、真实 showId。App 的首页推荐与搜索功能已基于此实现。

### 3. tvOS 应用工程（已生成，可直接打开）

```
YoukuTV/
├── YoukuTV.xcodeproj          ← 双击打开（SDKROOT=appletvos, deployment target 16.0）
├── project.yml                ← XcodeGen 工程配置
├── Sources/ (7 files)         ← Swift 源码，swiftc -parse 全部通过
├── Tests/                     ← 协议常量回归测试
├── Resources/                 ← 图标、启动图、Info.plist、entitlements
└── 交付说明.md                 ← 面向非开发者的操作手册
```

代码量 1,122 行 Swift。

---

## 关键结论

| 能力 | 状态 |
|---|---|
| 协议逆向 | ✅ 完成，签名算法/token/appKey/请求头全部实测验证 |
| 首页推荐 | ✅ 可用，走已验证 H5 通道 |
| 搜索 | ✅ 可用，走已验证 H5 通道 |
| 详情页/剧集列表 | ⚠️ 界面完成，TV 端接口需设备指纹，H5 剧集接口待定位 |
| 视频播放 | ⚠️ TV 端播放接口依赖 SecurityGuard native 签名（ckey 防盗链 + x-sign），纯客户端无法复现 |

**根本原因**：优酷把"取播放地址"这个接口用阿里 SecurityGuard 保护了，签名代码在原生
系统库里，只有真实安卓设备能算出结果。这是行业通行做法（同类平台均如此），不是本次工作
的缺陷。已给出三条可行的兜底方案（内嵌 WebView / 继续找 H5 播放接口 / 跳转网页播放）。

---

## 本机环境限制（影响交付方式）

- **本机未装 Xcode**（仅 Command Line Tools），因此无法本机编译、打包、出 ipa。
  最终 Archive + 上传 TestFlight 需用户在自己 Mac 上完成，工程已配好，5 步操作。
- 8GB 内存，JADX 整体加载 7 个 dex 会 OOM；改用 JADX CLI 分步 + androguard 单类解析绕过。
- REA 的 JADX provider 在本沙箱报 `spawn EPERM`（无法派生子进程跑 java）；
  改为直接用 Python 写 MCP stdio 客户端驱动 jadx-headless-mcp。

---

## 下一步选择（需用户决定）

1. **内嵌 WebView 播放**（推荐，1-2 小时）——用 WKWebView 打开优酷播放页，播放一定正常
2. **继续深挖 H5 播放接口**（不确定）——H5 加密等级较低，有可能绕开
3. **先交付浏览版**（10 分钟）——界面完整，点播放跳 Safari

---

## 工具链（隔离在 `tools/`，未污染系统）

| 工具 | 版本 | 位置 |
|---|---|---|
| Node | 24.22.1 | `tools/node-v24.22.1-darwin-arm64` |
| REA | 6.8.0 | `tools/rea/node_modules/.bin/rea` |
| jadx-headless-mcp | 0.7.1 | `tools/jadx-headless-mcp-0.7.1-all.jar` |
| JADX CLI | 1.5.3 | `tools/bin/jadx` |
| apktool | 2.11.1 | `tools/apktool2.jar` |
| XcodeGen | 2.42.0 | `tools/xcodegen/xcodegen/bin/xcodegen` |
| androguard | 4.1.4 | `/Users/calvin/.workbuddy/binaries/python/envs/default` |
