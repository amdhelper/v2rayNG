import hilog from '@ohos.hilog';

/**
 * Logging facade — the HarmonyOS counterpart of com.v2ray.ang.util.LogUtil.
 *
 * Two sinks:
 *   1. hilog, so `hdc shell hilog` shows the app's trail.
 *   2. an in-memory ring buffer, so the in-app Logcat page works without
 *      adb access.
 *
 * Never log credentials, full proxy URLs, private keys or exported configs.
 */
const DOMAIN = 0xA2D0;
const TAG = 'v2rayNG';

const RING_LIMIT = 2000;

class Ring {
  private buf: string[] = [];
  private listeners: Array<(line: string) => void> = [];

  push(line: string): void {
    this.buf.push(line);
    if (this.buf.length > RING_LIMIT) {
      this.buf.splice(0, this.buf.length - RING_LIMIT);
    }
    for (const l of this.listeners) {
      l(line);
    }
  }

  all(): string[] {
    return this.buf.slice();
  }

  clear(): void {
    this.buf = [];
  }

  subscribe(fn: (line: string) => void): void {
    this.listeners.push(fn);
  }

  unsubscribe(fn: (line: string) => void): void {
    const i = this.listeners.indexOf(fn);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}

export const logRing = new Ring();

function stamp(): string {
  const d = new Date();
  const p2 = (n: number): string => n < 10 ? '0' + n : '' + n;
  const p3 = (n: number): string => n < 10 ? '00' + n : (n < 100 ? '0' + n : '' + n);
  return `${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}.${p3(d.getMilliseconds())}`;
}

function emit(level: string, msg: string): void {
  logRing.push(`${stamp()} ${level} ${msg}`);
}

export class Log {
  static i(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
    emit('I', msg);
  }

  static w(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
    emit('W', msg);
  }

  static e(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
    emit('E', msg);
  }

  static d(msg: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', msg);
    emit('D', msg);
  }

  /** Appends raw core output (may contain many lines) to the ring buffer. */
  static core(text: string): void {
    if (!text) {
      return;
    }
    for (const line of text.split('\n')) {
      if (line.length > 0) {
        emit('C', line);
      }
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'core: ' + text);
  }
}
