// Shim for @ohos.buffer under Node: the real module wraps the platform Buffer,
// so delegating to Node's Buffer exercises the same UTF-8/base64 semantics the
// port relies on (FmtUtil.base64Encode/Decode, percent-encoding).
export default {
  from: (data, encoding) => Buffer.from(data, encoding === undefined ? 'utf-8' : encoding)
};
