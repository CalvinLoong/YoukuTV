# YoukuTV —— Apple TV 上的优酷客户端

给 Apple TV 做的优酷客户端，**不需要 Xcode、不需要 99 美元开发者账号**。

```
代码 → GitHub 云端编译 → .ipa → Sideloadly 免费签名 → Apple TV
```

---

## 现在什么状态

| 功能 | 状态 |
|---|---|
| 首页分类推荐 | ✅ 真实优酷内容 |
| 搜索 | ✅ 真实优酷内容 |
| 详情页 / 剧集列表 | ✅ 界面完成 |
| 视频播放 | ✅ 原生 AVPlayer，多清晰度 + 自动码率 |

**代码 2403 行，9 个 Swift 文件。**
**已在 GitHub 云端真机环境编译通过（Xcode 26.3 / tvOS SDK 26.2，零错误零警告）**，
安装包已发布到 Releases。播放链路用真实网络数据端到端验证通过。

---

## 三步装上

### 1. 下载安装包（已编译好，直接下）

<https://github.com/CalvinLoong/YoukuTV/releases> → 展开 **v1.0.0** →
下载 `YoukuTV-unsigned.ipa`（约 230KB）

> 不想点网页？在访达里双击 `安装到AppleTV.command`，
> 脚本会自动检查安装包、引导你走完整个流程。

### 2.（可选）自己重新编译

改了代码才需要。打开 <https://github.com/CalvinLoong/YoukuTV/actions>
→ 选 **Build tvOS IPA (unsigned)** → **Run workflow** → 等约 5-8 分钟。

> 构建机默认走 Intel 池（`macos-*-intel`），实测秒级拿到机器。
> arm64 池（`macos-latest` / `macos-15`）供给紧张，排队可能十几分钟。

### 3. 装进 Apple TV

1. 电脑装 [Sideloadly](https://sideloadly.io)（免费，支持 Apple TV）
2. Apple TV 和电脑连同一个 WiFi
3. Apple TV → **设置 → 遥控器与设备 → 远程 App 与设备**，记下配对码
4. Sideloadly 里拖入 ipa → 选你的 Apple TV → 填免费 Apple ID → **Start**
5. Apple TV → **设置 → 通用 → 隐私与安全性 → App 安装** → 信任开发者

> 免费 Apple ID 签名 **7 天过期**。开启 Sideloadly 的 `Auto-Refresh` 可自动续签，
> 否则过期后重新装一次（数据和登录状态不丢）。

---

## 播放是怎么解决的

优酷给"取播放地址"加了设备级加密（ckey 防盗链），由浏览器安全组件算出。
tvOS 既**没有浏览器引擎**（Apple 官方：tvOS has no WKWebView at all），
优酷的 HTML 页面又有阿里 x5 风控，所以"抓网页"这条路在 tvOS 上走不通。

最终方案是**全程只走 JSON 接口**：

```
搜索  search.youku.com/api/search   →  vid + 权益标签 + 集数
      ↓
地址  un-acs.youku.com ups          →  m3u8
      ↓
播放  AVPlayer（原生）
```

关键突破是发现**搜索接口本身就带着可播放的 vid**
（`leftButtonDTO.action.value`，覆盖率 75~100%），因此完全不必访问网页。

主播放列表（`auto` 那条）的 `m3u8_url` 装的是清单**内容**而非 URL，
App 会把它落盘成临时 m3u8 交给 AVPlayer，从而获得
**1080p / 720p / 486p / 360p 自动码率切换**。

### 权益边界

VIP / 付费内容优酷会返回空地址（服务端校验会员权益后才下发）。
**本项目有意不做会员校验绕过**，App 会明确提示
"「XXX」为优酷VIP内容，需要会员账号才能播放"。

免费内容实测全部可播（《甄嬛传》5 集免费全可播，71 集会员按设计不可播）。

---

## 自己检查一遍

```
python3 tools/一键自检.py
```

输出：

```
  ✓ 编译        ← 用 macOS SDK 做等价编译，30 秒出结果
  ✓ 凭据        ← 内置 ckey 是否还有效
  ✓ 链路        ← 搜索 → 取 vid → 取播放地址（真实网络请求）
```

单项也可以单独跑：

```
python3 tools/本地编译检查.py       # 本机没 Xcode 也能跑
python3 tools/校验凭据.py
python3 tools/回归测试.py 庆余年 甄嬛传
```

---

## 凭据失效了怎么办

服务端会轮换 ckey（表现为接口返回 SUCCESS 但没有地址）。
双击 `更新ckey.command` 重新生成（约 1 分钟，用真实浏览器抓一次），
然后提交推送、Actions 重新编译。

`tools/校验凭据.py` 可以随时检查当前凭据是否还有效。

---

## 文档

| 文件 | 内容 |
|---|---|
| `逆向分析报告.md` | 1303 行，每条结论标注实测证据，含反例与修正记录 |
| `零成本安装指南.md` | 面向没有开发背景的用户 |
| `安装到AppleTV.command` | 一键脚本：检查安装包 → 触发编译 → 下载 → 引导安装 |
| `overview.md` | 项目总览与技术决策 |
| `circleci-备用配置.yml` | GitHub 长期排队时的备用 CI 方案 |

---

## 常见问题

**搜索结果打开是别的节目？**
已修复。之前搜索接口会混入外站（腾讯/咪咕）内容，它们的 showId 指向别的节目。
现在只保留优酷自有内容，并拒绝被 UTF-8 替换字符污染的 showId。

**详情页显示"选集列表加载失败"？**
优酷的网页有风控，选集列表拿不到。**不影响播放**——播放用的是搜索接口直出的 vid。
点「重试」可能成功。

**能看会员内容吗？**
不能，这是有意的边界。见上文「权益边界」。

**为什么源码里的 ckey 是明文的？**
它是设备指纹签名，不是账号凭据。绑定的是 utid（设备标识）+ vid 之外的通用属性，
且不绑定具体视频——所以一份凭据能取任意视频的播放地址。
