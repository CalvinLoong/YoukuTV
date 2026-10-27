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

28 个文件 / 164KB / 1,122 行 Swift，8 个源文件 `swiftc -parse` 全部通过。

### 4. 云端编译工作流

`.github/workflows/build-tvos-ipa.yml` — 9 步，输出未签名 .ipa，
YAML 与全部 shell 块已校验通过。

---

## 功能状态

| 能力 | 状态 |
|---|---|
| 首页分类推荐 | ✅ 真实优酷内容 |
| 搜索 | ✅ 真实优酷内容 |
| 详情页 / 剧集列表 | ✅ 界面完成 |
| 视频播放 | ⚠️ TV 端播放接口依赖 SecurityGuard native 签名（ckey 防盗链 + x-sign），纯客户端无法复现 |

**播放的三条出路**（待你选）：
- **A. 内嵌网页播放器**（1-2 小时，稳）— WKWebView 打开优酷播放页
- **B. 继续挖 H5 播放接口**（不确定）— H5 加密等级低，可能打通
- **C. 跳转 Safari**（10 分钟）— 点播放跳网页

---

## 现在你要做的（10 分钟）

1. GitHub 注册 → 建**公开**仓库
2. 把代码传上去（`git push` 或网页拖拽）
3. Actions → `Build tvOS IPA (unsigned)` → Run workflow
4. 等 10 分钟，下载 `.ipa`
5. 装 Sideloadly → 填免费 Apple ID → 装到 Apple TV

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
├── Sources/                      7 个 Swift 源文件
├── Tests/                        协议常量回归测试
├── Resources/                    图标 / Info.plist
├── project.yml                   XcodeGen 配置
└── 交付说明.md                    有开发者账号时的完整流程

.github/workflows/                云端编译工作流
零成本安装指南.md                   ← 你现在该看这个
逆向分析报告.md                    技术细节
磁盘清理方案.md                    清理指引
overview.md                       本文件
清理缓存.command / 清理应用缓存.command
```

---

## 法律提示

代码里的协议来自对 CIBN 酷喵影视 TV 客户端（`com.cibn.tv` v13.0.1.3）的逆向分析，
属学习性质，仅供个人自用测试。请勿用于商业分发或公开传播，勿用于访问付费内容。
