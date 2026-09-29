# v2rayNG for HarmonyOS NEXT / v2rayNG 纯血鸿蒙版

[HarmonyOS NEXT](https://consumer.huawei.com/cn/harmonyos-next/)（纯血鸿蒙）原生版
v2rayNG。原 Android 工程在旁边的 `V2rayNG/`，本目录是它的鸿蒙移植，Android 代码
一行未改。

- 平台：HarmonyOS NEXT（Stage 模型，ArkTS + ArkUI + NAPI + 原生内核）
- 内核：Xray-core（`native/libv2ray_ohos`，c-shared），数据面 hev-socks5-tunnel
- 许可：GPL-3.0（随原项目）

> ⚠️ 纯血鸿蒙没有 Android 运行时，跑不了 APK。这是**按鸿蒙能力重写**的移植。

## 快速开始

```bash
export HARMONY_HOME=~/harmonyos-sdk/command-line-tools

# ① 一次性：OHOS Go 工具链（必须先读 docs/OHOS_PORT.md 第 2 节）
bash scripts/bootstrap_ohos_go.sh

# ② 原生内核
bash scripts/build_native_all.sh

# ③ 纯逻辑门禁（不需要设备；改解析/配置后必跑）
bash scripts/verify_logic.sh

# ④ HAP
bash scripts/build_hap.sh debug
# → entry/build/default/outputs/default/entry-default-unsigned.hap
```

装真机请走自签流程（`harmonyos-hap-signing` 那套：三级证书链 + ECC profile +
`hdc install -r`）。**第三方 VPN 应用上架华为应用市场需要华为审核 VPN 扩展能力**，
自签只能自用/测试。

## 目录

```
V2rayNG-Ohos/
├── AppScope/                       应用级配置（bundleName / 图标 / 版本）
├── entry/src/main/
│   ├── module.json5                EntryAbility + V2RayVpnAbility(type: vpn) + 权限
│   ├── ets/
│   │   ├── entryability/           应用入口，装配 stores
│   │   ├── vpnability/             V2RayVpnAbility —— VPN 扩展（独立进程）
│   │   ├── pages/                  Index / ServerEdit / Settings / Logcat / About
│   │   ├── core/                   CoreNative / ConnectionController / XrayConfigBuilder
│   │   │                           / HevTunConfig / VpnFiles / DelayTask
│   │   ├── fmt/                    分享链接解析（vmess/vless/ss/trojan/hy2/…）
│   │   ├── model/                  Profile / ProfileStore / SubscriptionStore / AppSettings
│   │   └── util/                   Log
│   ├── cpp/                        NAPI 桥 napi_init.cpp + CMakeLists
│   │   └── prebuilt/arm64-v8a/     原生内核产物（构建生成，不入库）
│   └── resources/rawfile/          geoip.dat / geosite.dat（构建生成，不入库）
├── native/libv2ray_ohos/           Xray 内核的 c-shared 包装（自研 C ABI）
├── scripts/                        bootstrap / build_* / sync_geo_assets
│   └── logic_check/                host 侧回归门禁（语料 + 真实 xray-core 校验）
└── docs/OHOS_PORT.md               ★ 移植文档：架构、TLS 墙、构建、校验、已知缺口
```

**动手改代码前请先读 `docs/OHOS_PORT.md`。** 尤其是第 2 节：Go c-shared 库在
鸿蒙 musl 上必须用 `GOOS=openharmony` + TLSDESC 工具链编译，否则真机必崩；
以及"Go 库 dlopen 之后不能再 setenv"这条硬约束。

## 与原版的对应关系

| Android | HarmonyOS |
|---|---|
| `V2rayNG/` | `V2rayNG-Ohos/` |
| `VpnService` | `V2RayVpnAbility`（`VpnExtensionAbility`） |
| `CoreVpnService` / `CoreServiceManager` | `V2RayVpnAbility` / `ConnectionController` |
| `AndroidLibXrayLite`（gomobile AAR） | `native/libv2ray_ohos`（c-shared `.so`） |
| `service/TProxyService`（hev） | `libhevsocks5tun.so`（同一个 hev 子模块） |
| `core/CoreOutboundBuilder.kt` | `core/XrayConfigBuilder.ets` |
| `fmt/*.kt` | `fmt/*.ets` |
| `handler/MmkvManager.kt` | `model/ProfileStore.ets` + `@ohos.data.preferences` |

功能差距的**诚实清单**见 `docs/OHOS_PORT.md` 第 5 节。