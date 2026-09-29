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

## 4. 产物校验（每次改内核都要跑）

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
- 只实现了 4 个路由预设中的 3 个（bypass-mainland / bypass-lan / all），
  自定义 routing 规则集、ruleset 下载、balancer/策略组、observatory 未移植。
- FakeDNS 只有基础形态；`browser_dialer`（浏览器拨号）未移植。
- 自定义 JSON 配置（`EConfigType.CUSTOM`）的 process/UID 替换逻辑未移植
  （鸿蒙无 `getConnectionOwnerUid`，分应用路由改为依赖
  `VpnConfig.trustedApplications/blockedApplications`）。
- 流量统计走 `QueryAllOutboundTrafficStats`（与 Android 同名同格式），
  但 outbound 级别的分标签展示未做。

**协议**
- 节点链接解析覆盖 vmess/vless/ss/trojan/hysteria2/socks/v2rayN 格式；
  wireguard 的链接导入未做（出站构造已支持）。
- 原版支持的协议族与传输组合以 CoreOutboundBuilder 为准，移植版在
  `docs` 之外的对照见 `native/` 与 `core/XrayConfigBuilder.ets` 的注释。

**平台能力**
- `protectProcessNet()` 需要 **API ≥ 22**。低于该版本时无法保护内核自己的
  服务端 socket，默认路由会形成回环；代码会打警告并继续。旧版本设备建议
  改用局域网绕过模式（bypassLan）。
- 第三方 VPN 应用**上架华为应用市场需要华为审核 VPN 扩展能力**；
  本地自签只能自用/测试。
- 桌面/太平等形态未做（`deviceTypes` 写了 phone/tablet/2in1，但 UI 按手机布局）。

**其他**
- 订阅 URL 拉取用明文 http 客户端（与 Android 一致），未加计量/重试策略。
- 开机自启、常驻通知、快捷开关（Android 的 QSTile/Widget/Tasker）未移植。
- 未移植 root 模式、TProxy/局域网共享。

---

## 6. 参考实现

同类鸿蒙原生移植的公开实现，本移植在原生层与它们的技术路线一致（musl/TLSDESC
那条结论是共通的），遇到问题时值得对照：

- `shadowsocks/shadowsocks-ohos` —— ArkTS + Rust 核心 + NAPI，`VpnExtensionAbility`
  的用法、`protectProcessNet` 的必要性、tun fd 交接方式写得很清楚。
- `popsiclelmlm/Hey` —— ArkTS + Go(xray) + NAPI，同样踩过 Go-on-musl 的 TLS 墙，
  `docs/harmonyos-go-tls-wall.md` 与 `docs/building-native-cores.md` 的排查过程
  与本仓库第 2 节结论一致。