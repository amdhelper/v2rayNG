/**
 * Thin ArkTS facade over the NAPI bridge `libv2rayngohos.so`.
 *
 * The bridge is the HarmonyOS counterpart of
 * V2rayNG/app/src/main/java/com/v2ray/ang/core/CoreNativeManager.kt
 * (which wraps the gomobile-generated `libv2ray` AAR).
 *
 * Two native cores live behind one module:
 *   - libv2rayohos.so   Go  c-shared  — Xray core (see native/libv2ray_ohos)
 *   - libhevsocks5tun.so C            — tun2socks data plane (hev-socks5-tunnel)
 *
 * Both are dlopen'ed lazily by the bridge, because environment variables that
 * the Go runtime must see (XRAY_LOCATION_ASSET, xray.xudp.basekey) have to be
 * set BEFORE the first dlopen. See docs/OHOS_PORT.md §"dlopen 之后不要 setenv".
 */
import nativeBridge from 'libv2rayngohos.so';

export class CoreState {
  static readonly STOPPED: number = 0;
  static readonly STARTING: number = 1;
  static readonly RUNNING: number = 2;
  static readonly ERROR: number = 3;
}

interface BridgeAck {
  success: boolean;
  error?: string;
  state?: number;
}

export class CoreNative {
  /** Bridge ABI version. */
  static libVersion(): number {
    return nativeBridge.xrayLibVersion() as number;
  }

  /** e.g. "Lib v1, Xray-core v1.260327.1". */
  static checkVersionX(): string {
    return nativeBridge.xrayCheckVersionX() as string;
  }

  /**
   * Optional: absolute directory holding the packaged .so files. The bridge
   * falls back to a bare-soname dlopen when it is not set.
   */
  static setNativeLibDir(dir: string): void {
    nativeBridge.setNativeLibDir(dir);
  }

  /**
   * Sets XRAY_LOCATION_ASSET + the XUDP base key. Must be called before the
   * first start; the bridge refuses (and returns false) once any Go core has
   * been dlopen'ed, because setenv after that can crash the Go runtime.
   */
  static setCoreEnv(assetDir: string, xuKey: string): boolean {
    return nativeBridge.setCoreEnv(assetDir, xuKey) as boolean;
  }

  /** Starts the core asynchronously; returns an ack JSON. */
  static startLoop(configJson: string): BridgeAck {
    const raw = nativeBridge.xrayStartLoop(configJson) as string;
    return JSON.parse(raw) as BridgeAck;
  }

  static stopLoop(): BridgeAck {
    const raw = nativeBridge.xrayStopLoop() as string;
    return JSON.parse(raw) as BridgeAck;
  }

  static state(): number {
    return nativeBridge.xrayState() as number;
  }

  static lastError(): string {
    return nativeBridge.xrayLastError() as string;
  }

  /** Returns and clears accumulated core log text. */
  static drainLogs(): string {
    return nativeBridge.xrayDrainLogs() as string;
  }

  /**
   * "tag,direction,value;tag,direction,value;" and resets the counters.
   * Mirrors AndroidLibXrayLite's QueryAllOutboundTrafficStats.
   */
  static queryAllOutboundTrafficStats(): string {
    return nativeBridge.xrayQueryAllOutboundTrafficStats() as string;
  }

  /** Real-connection delay in ms, negative on failure. */
  static measureOutboundDelay(configJson: string, testUrl: string, timeoutMs: number): number {
    return nativeBridge.xrayMeasureOutboundDelay(configJson, testUrl, timeoutMs) as number;
  }

  // --- tun2socks (hev-socks5-tunnel) --------------------------------------

  /** Starts the blocking hev tunnel on a background thread. 0 = accepted. */
  static hevStart(configYaml: string, tunFd: number): number {
    return nativeBridge.hevStart(configYaml, tunFd) as number;
  }

  static hevStop(): number {
    return nativeBridge.hevStop() as number;
  }

  /** JSON: {"txPackets":n,"txBytes":n,"rxPackets":n,"rxBytes":n} */
  static hevStats(): string {
    return nativeBridge.hevStats() as string;
  }

  static hevRunning(): boolean {
    return nativeBridge.hevRunning() as boolean;
  }
}