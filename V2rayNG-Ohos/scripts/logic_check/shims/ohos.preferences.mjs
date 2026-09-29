// Shim for @ohos.data.preferences: an in-memory key/value store with the same
// async surface (getPreferences/put/getSync/flush) the stores use.
const stores = new Map();
function makeStore(name) {
  const data = new Map();
  return {
    async put(key, value) { data.set(key, value); },
    getSync(key, def) { return data.has(key) ? data.get(key) : def; },
    async flush() {}
  };
}
export default {
  async getPreferences(_ctx, name) {
    if (!stores.has(name)) stores.set(name, makeStore(name));
    return stores.get(name);
  }
};
