# v2rayNG 纯血鸿蒙版（HarmonyOS NEXT）移植文档

本目录是 [2dust/v2rayNG](https://github.com/2dust/v2rayNG) 的 **HarmonyOS NEXT
（纯血鸿蒙）原生移植**，与旁边的 Android 工程 `V2rayNG/` 并列存在于同一个
fork 中。Android 代码一行未改。

- 许可证：GPL-3.0（随原项目）
- 目标平台：HarmonyOS NEXT（Stage 模型，ArkTS + NAPI + 原生内核）
- 编译 SDK：HarmonyOS 6.1.1 (API 24)，兼容 5.0.0(12)+

> **重要认知**：纯血鸿蒙 **没有 Android 运行时**，不能跑 APK，也不能用
> JVM/gomobile。因此这不是"打包移植"，而是"把 Android 版的功能按鸿蒙的
> 能力重写一遍"，其中最难的一层是**原生内核（Go）在鸿蒙 musl 上的加载问题**。

---

## 1. 架构：数据面怎么走

Android 版的数据面是 `VpnService` → libv2ray（gomobile AAR）→ 或
hev-socks5-tunnel（TUN 模式）。鸿蒙版严格对应：

```
应用流量
  └─ HarmonyOS VPN TUN（vpnExtension.createVpnConnection 拿到的 fd）
      └─ libhevsocks5tun.so   hev-socks5-tunnel，跑在 worker 线程
          └─ 127.0.0.1:<socksPort>   Xray 的本地 socks 入站
              └─ libv2rayohos.so     Xray 内核，出站 = 选中节点
                  └─ 真实服务端
```

三层与原版的一一对应：

| Android | HarmonyOS | 说明 |
|---|---|---|
| `VpnService.Builder` + `ParcelFileDescriptor` | `vpnExtension.createVpnConnection(ctx).create(cfg)` → tun fd | 建虚拟网卡、路由、DNS、分应用代理 |
| `VpnService.protect(socket)` 回调 | `VpnConnection.protectProcessNet()`（API ≥ 22） | **必需**，否则内核自己连服务端的 socket 会被回灌进隧道 → 死循环 |
| `CoreVpnService` / `CoreServiceManager` | `V2RayVpnAbility` / `ConnectionController` | 生命周期编排（跨进程） |
| `AndroidLibXrayLite`（gomobile `libv2ray.aar`） | `native/libv2ray_ohos`（c-shared `libv2rayohos.so`） | 同一个 Xray 内核，换成扁平 C ABI |
| `TProxyService`（hev） | `libhevsocks5tun.so` | 同一个 hev-socks5-tunnel 源码（本仓库子模块） |

### 1.1 为什么内核要换成 c-shared + 自研 C ABI

Android 侧用 `gomobile bind` 生成 `libv2ray.aar`（`go.Seq`、`libv2ray.CoreController`、
JNI 回调）。鸿蒙没有 JVM，也没有 gomobile 目标平台，所以 `native/libv2ray_ohos/`
把 `AndroidLibXrayLite/libv2ray_main.go` 的能力重写成**扁平 C ABI**：

- 去掉 `go.Seq` / `mobasset`；
- **回调一律改成轮询**。cgo 函数指针回调要求宿主 `.so` 的符号对 dlopen 进来的 Go
  库全局可见，很容易崩；改成 `state / lastError / drainLogs` 三个轮询接口，简单可靠；
- 仍是同一份 xray-core，仍是同一套 xray JSON 配置格式。

导出符号（`llvm-nm -D libv2rayohos.so` 应只见这些，其余由 version-script 隐藏）：

```
V2RayOhosLibVersion                  V2RayOhosGetState
V2RayOhosCheckVersionX               V2RayOhosGetLastError
V2RayOhosStartLoop                   V2RayOhosDrainLogs
V2RayOhosStopLoop                    V2RayOhosQueryAllOutboundTrafficStats
V2RayOhosMeasureOutboundDelay        V2RayOhosFree
```

`napi_init.cpp` 只 `dlsym` 这些符号；主模块对 ArkTS 暴露的是
`CoreNative.ets` 里那套 `xrayStartLoop / xrayState / hevStart / ...`。

### 1.2 跨进程

`VpnExtensionAbility` 跑在**独立进程**里，所以 UI 进程和扩展进程不能共享 ArkTS
状态。两边只通过 bundle `filesDir` 下的三个文件通信（`VpnFiles.ets`）：

| 文件 | 方向 | 内容 |
|---|---|---|
| `vpn_request.json` | UI → 扩展 | 生成的 xray 配置、hev yaml、DNS/MTU/分应用列表 |
| `vpn_status.json` | 扩展 → UI | 状态机、错误信息、上下行字节数 |
| `vpn_core.log` | 扩展 → UI | Xray 内核日志（Logcat 页读它） |

启动 = 写 request + `startVpnExtensionAbility`；停止 = `stopVpnExtensionAbility`
（落到 `onDestroy`）。不依赖 Want 传大 payload，也不依赖跨进程 preferences。

---

## 2. 核心难点：Go cgo 的 TLS 墙

**这是整个移植唯一"不做就必崩"的地方，务必先读这一节。**

HarmonyOS NEXT 用 **musl** libc（`ld-musl-aarch64.so.1`），而 Go 在 arm64 上把
goroutine 指针 `g` 放在线程本地存储（TLS）里。怎么放，决定了 c-shared 库能不能
被 `dlopen`、外来线程（ArkTS / VPN 扩展）能不能调 cgo：

| 编法 | `g` 存哪 | 在鸿蒙上的结果 |
|---|---|---|
| 标准 Go + `GOOS=android` | bionic 固定 TLS 槽 | `dlopen` 能过，但外来线程那个槽是垃圾 → cgo→Go **SIGSEGV** |
| 标准 Go + `GOOS=linux` | initial-exec TLS | musl **拒绝 dlopen** 含 IE-TLS 的库 → 整个原生桥加载失败 |
| **OHOS Go fork + `GOOS=openharmony`** | **TLSDESC（通用动态 TLS）** | `dlopen` 能过 **且** 外来线程 cgo 正常 ✅ |

因为鸿蒙应用里跑 Xray 的线程是鸿蒙自己的线程，不是 Go 自己起的线程，所以只有
第三条路能用。这需要两件事：

1. **一个带 `openharmony` 端口的 Go 工具链**：
   `star4277/ohos-go` tag `v1.26.5-beta1`（go1.26.5，arm64 补了 TLSDESC）。
   本仓库用 `scripts/bootstrap_ohos_go.sh` 一键构建（自举需要 ≥ go1.24.6）。
2. **`CGO_CFLAGS=-ftls-model=global-dynamic`**：把其余 initial-exec TLS 重定位
   也去掉 —— musl 在 `dlopen` 的库里只接受通用动态 TLS。

另外两条硬约束：

- **不能加 `-tags netgo`**：openharmony 的 net 端口需要 cgo，加了会报
  `_C_getifaddrs undefined`。
- **Go 库 `dlopen` 之后不要再 `setenv`**：Go 只在运行时初始化时把 `environ`
  拷贝一次；此后 C 侧 `setenv` 会让 musl realloc/free 旧数组，而 c-shared 的
  异步初始化线程正在读它 → SIGSEGV。所以 `XRAY_LOCATION_ASSET`、
  `xray.xudp.basekey` 必须在**第一次 dlopen 之前**设好 ——
  `napi_init.cpp` 的 `gGoLibLoaded` 守卫就是为了这个，`setCoreEnv()` 在库已加载
  后会**拒绝**执行并返回 false。

### 2.1 工具链版本约束

| | Android 版（本仓库 `AndroidLibXrayLite`） | 鸿蒙版（本仓库 `native/libv2ray_ohos`） |
|---|---|---|
| go.mod `go` | **1.27** | 1.26 |
| xray-core | `v1.260327.1-0.20260908222543-52a412d9e2f5`（2026-09-08） | `v1.260327.1-0.20260728075948-5ca6f4b7d4dc`（2026-07-28，钉版） |

**鸿蒙内核版本落后于 Android 内核，原因不是我们懒**：目前没有任何
OpenHarmony Go fork 支持 go1.27，而 Android 侧的 go.mod 已声明 `go 1.27`。
所以鸿蒙侧的 xray-core 钉在最后一个能编的版本（2026-07-28），
等有支持 go1.27 的 OHOS fork 再升。

升级步骤：改 `native/libv2ray_ohos/go.mod` 的 require → 重跑
`scripts/build_libv2ray_ohos.sh`。**升级前先确认新版本的
`infra/conf/serial` 与 `features/stats` API 没变**（本包装用到
`LoadJSONConfig` / `core.New` / `Manager` / `VisitCounters` / `Counter.Set`）。

---

## 3. 构建

### 3.1 一次性：准备工具链

```bash
# 需要：HarmonyOS Command Line Tools（提供 ohos clang + hvigor + ohpm）
export HARMONY_HOME=~/harmonyos-sdk/command-line-tools

# OHOS Go fork（放到仓库外！hvigor clean 会删 <repo>/build）
bash scripts/bootstrap_ohos_go.sh          # 默认装到 ~/ohos-build/ohos-go-1.26.5
```

自检：

```bash
~/ohos-build/ohos-go-1.26.5/bin/go version                       # go1.26.5
~/ohos-build/ohos-go-1.26.5/bin/go tool dist list | grep openharmony
#   openharmony/amd64
#   openharmony/arm64
```

### 3.2 编原生内核

```bash
bash scripts/build_native_all.sh
# = build_libv2ray_ohos.sh  (Go c-shared)
# + build_hev_ohos.sh       (C，只用 OHOS clang，不需要 Go fork)
# 产物 → entry/src/main/cpp/prebuilt/arm64-v8a/{libv2rayohos.so,libhevsocks5tun.so}
```

### 3.3 编 HAP

```bash
bash scripts/build_hap.sh debug --with-native
# 或先 3.2 再：
bash scripts/build_hap.sh debug
# 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

`build_hap.sh` 会调用 `scripts/sync_geo_assets.sh`，把
`AndroidLibXrayLite/assets/{geoip,geosite}.dat` 复制进
`entry/src/main/resources/rawfile/`（这两个副本已 gitignore，27 MB，随子模块走）。

---

## 4. 校验：两层门禁

### 4.1 纯逻辑门禁（不需要设备，改解析/配置后必跑）

```bash
bash scripts/verify_logic.sh
```

它做三件事，任何一步红就非零退出：

1. 把 `entry/src/main/ets/` 的纯逻辑源码（`.ets` 当 `.ts`）用 esbuild 打成一份 Node 可跑的
   bundle，`@ohos.*` 用 shims 顶掉（`scripts/logic_check/shims/`）；
2. 跑一组合法的分享链接语料 + 一组**必须解析失败**的负向用例，断言每个字段；
   再把每条 profile 生成的配置（完整配置 / 测速配置）写进 `out/`，出站片段写进 `out-fragments/`；
3. **把 `out/` 里的每一份配置喂给钉版 xray-core**（`serial.LoadJSONConfig` + `core.New`，
   和桥里调的是同两个函数）。

第 3 步是关键：它抓的是「生成器产出消费端不接受的东西」。实测它在开发期抓出了三个真问题：

- **`V2rayNFmt` 用 `=== null` 判 JSON 缺失字段**——JSON 里缺失的键是 `undefined`，
  于是任何省略可选子对象的 v2rayN 条目都会抛异常；
- **同一处把 `undefined` 直接赋给 `string` 字段**，后续 `.trim()` 才炸——
  已统一经 `opt()` 归一化；
- 语料里 WireGuard 的密钥不是合法 base64（41 字符），core 会拒整个出站。

两份**故意失败**的用例（`90-upstream-h2.json`、`91-upstream-allowinsecure.json`）由
`out/expected_failures.json` 声明，校验器要求它们**必须失败且错误信息含指定理由**——
这样 §6 的两条结论是**可执行断言**，不是文档承诺。另外校验器会拒绝 `outbounds` 为空的
输入，防止「拿碎片当整份配置验」这种**假绿**。

它**不覆盖**：NAPI 桥、VPN 扩展、任何需要平台的东西。那些只有编 HAP + 真机才能验。

### 4.2 原生产物指纹（每次改内核都要跑）

```bash
SO=entry/src/main/cpp/prebuilt/arm64-v8a/libv2rayohos.so
LLVM=$HARMONY_HOME/sdk/default/openharmony/native/llvm/bin

# 1) 确是 openharmony 产物 + 工具链版本
strings -a "$SO" | grep -m1 'GOOS=openharmony'
strings -a "$SO" | grep -m1 -o 'go1\.26\.[0-9]*'

# 2) 导出集
$LLVM/llvm-nm -D "$SO" | grep ' T V2RayOhos'

# 3) TLSDESC 落地（本路线的关键标志，缺了真机必崩）
$LLVM/llvm-readelf -l "$SO" | grep -i TLS       # 应有 PT_TLS
$LLVM/llvm-readelf -r "$SO" | grep -i TLSDESC   # 应有 R_AARCH64_TLSDESC

# 4) hev 侧
$LLVM/llvm-nm -D entry/src/main/cpp/prebuilt/arm64-v8a/libhevsocks5tun.so \
  | grep hev_socks5_tunnel
#   hev_socks5_tunnel_main_from_str / hev_socks5_tunnel_quit / hev_socks5_tunnel_stats
```

**"能编"不等于"真机不崩"**。换工具链或升版本后必须重跑第 3 步，并在真机上验证
VPN 扩展进程调 cgo 不 SIGSEGV。

排查的手法（沿用已验证的路径）：清空 hilog → 真机点连接 → 看
`com.<pkg>:vpn` 进程是否在写任何回执前就没了。栈里出现
`ArkNativeFunctionCallBack` → `libv2rayngohos.so` → `libv2rayohos.so`
第一个 cgo 调用附近且地址像野指针，就回到第 2 节重新审视 TLS 模型。

---

## 5. 已知缺口（诚实清单）

本目录是**能编译、结构完整**的第一版基础，不是功能对齐版。相对 Android 版的差距：

**路由/配置**
- 路由预设里只有 `bypass-mainland` / `bypass-lan` 会生成内置直连规则
  （`XrayConfigBuilder.routingRules()`）。`all` 与 `global` 都是"不加规则、全部走
  第一个出站"，`custom` **没有规则编辑界面**、行为与 `global` 相同——设置页的
  下拉标签已如实写成"全局代理（与第一项相同）"和"自定义规则（未实现，等同全局）"，
  不让用户以为自定义规则生效了。自定义 routing 规则集、ruleset 下载、
  balancer/策略组、observatory 未移植。
- FakeDNS 只有基础形态；`browser_dialer`（浏览器拨号）未移植。
- 自定义 JSON 配置（`EConfigType.CUSTOM`）**已支持连接**：
  `XrayConfigBuilder.buildCustom()` 把存的原始 JSON 原样使用，并按上游
  `buildV2rayCustomConfig` 注入 `stats`/`policy`。仍缺两块：
  (a) `process` 路由规则的「包名 → UID」替换（鸿蒙无 `getConnectionOwnerUid`，
  规则原样透传，等于不生效）；(b) tun inbound 注入（只在非 HEV TUN 模式下才会走到，
  本移植恒用 hev）。
  原始 JSON 存在 `ProfileItem.rawJson` 上（Android 侧放在
  `MmkvManager.decodeServerRaw`；放实体上让持久化/去重/删除自动一起走，
  gson 会忽略这个多出来的键，两边存的 JSON 仍可互换）。
- 流量统计走 `QueryAllOutboundTrafficStats`（与 Android 同名同格式），
  但 outbound 级别的分标签展示未做。

**协议**
- 节点链接解析覆盖 vmess/vless/ss/trojan/hysteria2/socks/v2rayN 格式；
  wireguard 的链接导入未做（出站构造已支持）。
- 原版支持的协议族与传输组合以 CoreOutboundBuilder 为准，移植版在
  `docs` 之外的对照见 `native/` 与 `core/XrayConfigBuilder.ets` 的注释。

**平台能力**
- `protectProcessNet()` 需要 **API ≥ 22**。低于该版本时无法保护内核自己的
  服务端 socket，而路由表等价于默认路由，会形成回环；代码会打警告并继续，
  旧系统上 VPN 模式实际上不可用（见 §7.9）。
- 第三方 VPN 应用**上架华为应用市场需要华为审核 VPN 扩展能力**；
  本地自签只能自用/测试。
- 桌面/太平等形态未做（`deviceTypes` 写了 phone/tablet/2in1，但 UI 按手机布局）。

**分应用代理：选择器在鸿蒙上做不到，改用"填包名 + 逐个核验"**
- 安卓版是列出全部已装应用让用户勾选。鸿蒙**没有这个 API**：
  `@ohos.bundle.bundleManager.d.ts` 只有 `getBundleInfoForSelf()` 和按包名查的
  `getBundleInfo()`，**不存在 `getAllBundleInfo()`**；枚举全部应用所需的
  `GET_BUNDLE_INFO_PRIVILEGED` / `ENTERPRISE_GET_ALL_BUNDLE_INFO` 是
  `system_basic` 级（`availableLevel` 查自 SDK 的 `PermissionDefinitions.json`），
  第三方应用拿不到。这不是本移植偷懒，是平台限制。
- 因此名单由用户填包名（逗号分隔），`core/AppResolver.ets` 用
  `ohos.permission.GET_BUNDLE_INFO`（normal 级、system_grant，已写进 module.json5）
  逐个核验并在设置页标注"已安装（版本 x.y.z）/ 未找到"。**这一步是必要的**：
  `VpnConfig` 对不认识的包名只是静默忽略，不核验的话用户会以为名单生效了。
- 名单切分只有**一个实现**（`AppResolver.splitNames`）：设置页用它核验、
  `ConnectionController` 用它填 `VpnConfig`。曾经两边各切一套（一个按逗号，
  一个按逗号/空格/分号）——用户用空格分隔就会"页面显示 2 项核验通过、隧道只收到
  1 个拼在一起的包名并静默忽略"，门禁里有断言守着这个接缝。
- 数据面是通的：名单 → `ConnectionController` → `VpnConfig.trustedApplications`
  / `blockedApplications`（自身 bundleName 恒在 blocked 里，避免回环）。
  作用时机是**建立隧道的瞬间**，所以改名单要重连才生效。

**连接模式与本地代理：三个开关是真的没实现（已如实标注，不再假装生效）**
- `vpnMode`（"关闭后仅保留本地代理监听"）、`localProxyEnabled`、`httpPort`、
  `appendHttpProxy` 这四个设置项**改前改后都不影响行为**（用脚本扫过：在
  `model/AppSettings.ets` 里声明、在设置页里读写，但**全仓没有任何消费者**）。
- `appendHttpProxy` 在**鸿蒙上根本做不到**：安卓是
  `CoreVpnService.configurePlatformFeatures()` 里的
  `Builder.setHttpProxy(ProxyInfo.buildDirectProxy(...))`，而鸿蒙
  `@ohos.net.vpnExtension.d.ts` 的 `VpnConfig` **没有任何代理字段**（全文件搜
  "proxy" 零命中）。这不是没做，是平台没有。
- 其余三个属于**没做**："仅本地代理"模式需要在 UI 进程里直接
  `CoreNative.startCore(只含入站的配置)`、不经 VPN 扩展、并由 UI 侧自己维护状态，
  是一条**独立于 VPN 的连接路径**。它在没有真机的情况下无法验证，而它偏偏又在
  连接主路径上——**宁可先不做也不塞一条没验证过的连接路径进去**（构建通过 ≠ 能用）。
  实现它的前提是先在真机上把 VPN 模式跑通。
- 设置页现在把这四项明确标成"未实现/不可实现"，并说明"开关会照常保存
  （便于与安卓版互相导入设置），但当前只有 VPN 模式真正生效"。反例是
  之前那句"应用选择器尚未实现，开关会保存但暂不生效"——它既没说清平台原因，
  而且在用户真填了包名之后**这句话还是错的**。

**其他**
- 订阅 URL 拉取用明文 http 客户端（与 Android 一致），未加计量/重试策略。
- 开机自启、常驻通知、快捷开关（Android 的 QSTile/Widget/Tasker）未移植。
- 未移植 root 模式、TProxy/局域网共享。

---

## 6. 钉版内核的能力边界（已逐条核实，不是猜测）

钉在 `xray-core v1.260327.1-0.20260728075948`（见 §2.1）。这个内核**主动移除**了若干
老特性，触发时返回的是**错误而不是警告**——错一份配置，整个内核起不来。逐条查过
`infra/conf/` 的源码，并和 **Android 侧钉的 `52a412d9e2f5`（2026-09-08）对比过目录树与代码**：

| 特性 | 钉版内核行为 | Android 侧是否一样 | 本移植的处理 |
|---|---|---|---|
| `h2` / `h3` / `http` / `quic` 传输 | `TransportProtocol.Build()` 里 `case "h2","h3","http":` 与 `case "quic":` 直接返回 `PrintRemovedFeatureError`，**硬拒绝** | **完全一样**（`transport/internet/{http,quic}` 目录在两个 commit 里都不存在） | 保留分支（与 Android 一致）。这些传输的节点在两端都用不了，属于上游行为；`ws`/`grpc`/`httpupgrade` 只是**弃用警告**（建议迁 XHTTP），仍可用 |
| `tlsSettings.allowInsecure` | `if c.AllowInsecure { return PrintRemovedFeatureError(...) }` —— **硬拒绝** | **完全一样** | 与 Android 一致仍会输出（`insecure == true && pinnedCA256 为空`），但**额外打一条 Log.w 说明后果**，避免只看到一个没法定位的 `config error` |
| kcp 的 `header` / `seed` | `if HeaderConfig != nil \|\| Seed != nil { return PrintRemovedFeatureError("mkcp header & seed", "finalmask/udp header-* & mkcp-original & mkcp-aes128gcm") }` | 一样（新 commit 里这两个字段已从结构体删除） | **已按上游给出的迁移路径实现**：不写 `kcpSettings.header/seed`，改写 `finalmask.udp` 里的 `mkcp-legacy` mask |
| **VLESS（`security=none`/空）或 Trojan 无 TLS，且服务端是公开地址** | `infra/conf/xray.go` 的 `requiresTransportSecurity()`：公开地址必须带传输加密，否则报 `without TLS or other encryption is prohibited` | **完全一样** | 保留行为。注意"公开"的判定：IP 必须落在私网段，域名必须命中 `private` 域规则；服务端是内网 IP 时反而不受限 |
| Trojan 的 `flow` | `infra/conf/trojan.go` → `PrintRemovedFeatureError("Flow for Trojan")` | **一样**（上游 `CoreOutboundBuilder.kt:196` 同样无条件发 `settings.flow`） | 保留行为 + 明确告警（曾误写成"本移植未产生该字段"，实际两端都会产生） |
| 全局 `transport` 配置 / `legacy reverse` / Legacy XTLS / `freedom.noise`(单数) | 同样 `PrintRemovedFeatureError` | 一样 | 本移植未产生这些字段 |

**上面的每一条都由 `scripts/logic_check` 的可执行断言守着**（见 §4.1）：`expected_failures.json`
声明"这些文件必须被拒且错误信息含指定理由"，改了内核或改了生成器都会当场变红。

另外 `XrayConfigBuilder.coreRejectionReasons(profile)` 在生成配置前会把这些已知拒绝原因
**列进日志**（连接前预检，`ConnectionController.start()` 也会打一条），
所以用户看到的是"该开 tls / 该清 flow / 该换 xhttp"这种可执行提示，
而不是只有一句 `config error`。行为本身不改——改了就跟上游不一致了。

结论：**纯血鸿蒙版没有因为内核版本落后而少功能**——上面这些限制 Android 版一模一样。
真正因工具链导致的差距只有一条：内核 revision 比 Android 侧早约 6 周（§2.1）。

还有一个上游地雷值得记住：`allowInsecure` 被移除，但上游自己的
`CoreOutboundBuilder.kt:560` **仍然在输出它**。也就是说，"节点用了自签证书且没配证书指纹"
这类节点，在 Android 版上同样会起不来。移植版选择**保持行为一致 + 明确告警**，而不是
偷偷替上游做决定。

---

## 7. 把 Android 工程搬进 ArkTS 时必踩的坑（本仓库实测）

这几条都是"编译过了才敢说"的硬经验，改写 Kotlin/Java 逻辑时逐条对照：

1. **以本机安装的 `.d.ts` 为准，不要信在线文档。** 在线文档里
   `vpnExtension.VpnConfig.addresses` 是 `Array<LinkAddress>` 且
   `LinkAddress = {address: string, prefixLength: number}`；而 6.1.1(24)
   实际安装的 `@ohos.net.connection.d.ts` 已经改成
   `LinkAddress = { address: NetAddress, prefixLength: number }`、
   `RouteInfo.gateway = NetAddress`，`NetAddress = {address, family?, port?}`。
   照在线文档写会得到一串 `Type 'string' is not assignable to type 'NetAddress'`。
   核对位置：`<SDK>/default/openharmony/ets/api/@ohos.net.connection.d.ts`。

2. **ArkTS 禁止按索引访问字段**（`arkts-no-props-by-index`）。
   `headers['User-Agent']`、`levels['0']` 这类写法过不了。
   xray 配置里天生带这种 JSON（`tcpSettings.header.request.headers`、
   `policy.levels`），官方 Kotlin 侧也是"先写 JSON 字面量再 parse"，
   **照它的做法用 `JSON.parse(literal) as X`** 即可，比自造结构安全。
   注意：带引号的非标识符字段名可以声明（`'User-Agent'?: string[]`），
   但不能用索引访问，只能用点号访问合法的那个（`headers.Host`）。

3. **禁止 `ESObject` / `any` / `unknown`**（`arkts-no-any-unknown`）。
   我第一版用 `conn as ESObject` 绕过高版本 API，直接报错。
   正确做法：**本地声明一个只含目标方法的小接口**（nominal 检查能过），
   再 `this.conn as Object as ThatInterface`，配 `typeof === 'function'` 判存在。
   这样 compatibleSdkVersion 能留在 5.0.0(12)。

4. **`@Builder` 里不要写 `this.参数名`**。`@Builder` 的参数是**裸参数**，
   `this.x` 只会去找 struct 的成员，于是报
   `Property 'x' does not exist on type '<Struct>'`（一次能报 20 条）。
   批量修法：定位 `@Builder` → 括号平衡取出形参名 → 在方法体内把
   `this.<形参>` 换成 `<形参>`。

5. **`Select` 没有 `fontSize()`**，字号要写 `.font({ size: 15 })`。

6. **`buffer.from(s,'utf-8')` 返回 `buffer.Buffer`**，不是 `Uint8Array`；
   显式标注成 `Uint8Array` 会报缺 15+ 个成员。用 `buffer.Buffer` 标类型。

7. **不要把"LAN 要绕过"写成"只路由 LAN"**。Android 的
   `AppConfig.ROUTED_IP_LIST` 是**私网段的补集**（0.0.0.0/5、8.0.0.0/7 … 240.0.0.0/4，
   共 31 条），语义是"除私网外全部进隧道"，等价于默认路由。
   写反了会出现"VPN 连上了但只有局域网流量走代理"。
   本仓库的 `ROUTED_IP_LIST` 是从 `AppConfig.kt` 逐条抄的。

8. **`VpnExtensionAbility` 是独立进程**。两边只能靠 `filesDir` 下的文件通信
   （请求/状态/日志三个文件），不要指望跨进程 `@ohos.data.preferences`；
   也别用 Want 传大 payload。

9. **`protectProcessNet()` 是 API ≥ 22**。没有它，内核自己连服务端的 socket
   会被上面那张"等于默认路由"的路由表回灌进隧道 → 死循环。
   代码里会打警告并继续；旧系统上 VPN 模式实际上不可用。

---

## 8. 参考实现

同类鸿蒙原生移植的公开实现，本移植在原生层与它们的技术路线一致（musl/TLSDESC
那条结论是共通的），遇到问题时值得对照：

- `shadowsocks/shadowsocks-ohos` —— ArkTS + Rust 核心 + NAPI，`VpnExtensionAbility`
  的用法、`protectProcessNet` 的必要性、tun fd 交接方式写得很清楚。
- `popsiclelmlm/Hey` —— ArkTS + Go(xray) + NAPI，同样踩过 Go-on-musl 的 TLS 墙，
  `docs/harmonyos-go-tls-wall.md` 与 `docs/building-native-cores.md` 的排查过程
  与本仓库第 2 节结论一致。