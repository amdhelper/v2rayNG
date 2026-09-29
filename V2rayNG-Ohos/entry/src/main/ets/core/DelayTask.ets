import { CoreNative } from './CoreNative';

/**
 * Runs on a taskpool worker so the UI thread is never blocked by the
 * (up to 12 second) native delay measurement.
 *
 * A @Concurrent function may not capture context, so only primitives cross the
 * boundary. The NAPI module is process-wide, so the worker can reach the same
 * dlopen'ed cores the UI thread uses.
 */
@Concurrent
export function measureDelayConcurrent(configJson: string, testUrl: string, timeoutMs: number): number {
  return CoreNative.measureOutboundDelay(configJson, testUrl, timeoutMs);
}
