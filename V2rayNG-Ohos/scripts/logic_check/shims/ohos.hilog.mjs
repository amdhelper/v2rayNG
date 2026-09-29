// Shim for @ohos.hilog. The port's Log facade also keeps an in-memory ring, so
// nothing is lost by silencing the platform sink here.
const noop = () => {};
export default { info: noop, warn: noop, error: noop, debug: noop, fatal: noop };
