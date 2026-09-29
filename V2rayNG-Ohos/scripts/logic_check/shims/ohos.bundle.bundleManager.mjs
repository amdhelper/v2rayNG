/**
 * Host shim for @ohos.bundle.bundleManager. The harness runs the port's pure
 * logic under Node, where there is no bundle manager: any call is a hard error
 * rather than a silent success, so a test that accidentally depends on the real
 * API fails loudly instead of passing for the wrong reason.
 */
export default {
  BundleFlag: { GET_BUNDLE_INFO_DEFAULT: 0, GET_BUNDLE_INFO_WITH_APPLICATION: 1 },
  async getBundleInfo() {
    throw new Error('logic_check: bundleManager.getBundleInfo is not available on the host');
  },
  async getBundleInfoForSelf() {
    throw new Error('logic_check: bundleManager.getBundleInfoForSelf is not available on the host');
  }
};
