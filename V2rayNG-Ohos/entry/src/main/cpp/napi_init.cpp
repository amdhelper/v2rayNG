/*
 * NAPI bridge for the v2rayNG HarmonyOS port.
 *
 * This file is the HarmonyOS counterpart of AndroidLibXrayLite's gomobile
 * binding layer plus V2rayNG's CoreNativeManager. One NAPI module
 * (`libv2rayngohos.so`) fronts two lazily dlopen'ed native cores:
 *
 *   libv2rayohos.so     Go  c-shared   Xray core          (native/libv2ray_ohos)
 *   libhevsocks5tun.so  C              tun2socks data plane (hev-socks5-tunnel)
 *
 * TWO INVARIANTS, both of which have bitten this port before:
 *
 *  1. Environment variables the Go runtime must observe (XRAY_LOCATION_ASSET,
 *     xray.xudp.basekey) have to be written with setenv() BEFORE the first
 *     dlopen of any Go c-shared library. Go copies `environ` once at runtime
 *     init, and a later setenv() makes musl realloc/free the array while Go's
 *     async init thread is reading it -> SIGSEGV. Hence g_goLibLoaded and
 *     the refusal in setCoreEnv().
 *
 *  2. Neither core may be touched before the VPN extension has created the TUN
 *     interface and (API >= 22) called protectProcessNet(), otherwise the core's
 *     own server connection is routed back into the tunnel.
 */

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <sys/types.h>
#include <unistd.h>

#include "napi/native_api.h"

// ---------------------------------------------------------------------------
// function pointer table for libv2rayohos.so
// ---------------------------------------------------------------------------

typedef int32_t (*fn_lib_version_t)();
typedef const char *(*fn_check_version_t)();
typedef const char *(*fn_start_loop_t)(const char *config);
typedef const char *(*fn_stop_loop_t)();
typedef int32_t (*fn_get_state_t)();
typedef const char *(*fn_get_last_error_t)();
typedef const char *(*fn_drain_logs_t)();
typedef const char *(*fn_query_stats_t)();
typedef int64_t (*fn_measure_t)(const char *config, const char *url, int32_t timeoutMs);
typedef void (*fn_free_t)(const char *p);

// ---------------------------------------------------------------------------
// function pointer table for libhevsocks5tun.so
// ---------------------------------------------------------------------------

typedef int (*fn_hev_main_from_str_t)(const unsigned char *cfg, unsigned int len, int tunFd);
typedef void (*fn_hev_quit_t)();
typedef void (*fn_hev_stats_t)(size_t *txPkts, size_t *txBytes, size_t *rxPkts, size_t *rxBytes);

namespace {

const char *kXrayLibName = "libv2rayohos.so";
const char *kHevLibName = "libhevsocks5tun.so";

pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

void *gXrayHandle = nullptr;
void *gHevHandle = nullptr;

// True once any Go c-shared library has been dlopen'ed in this process.
// After that point setenv() is forbidden (see invariant 1 above).
bool gGoLibLoaded = false;
bool gEnvPrepared = false;

std::string gNativeLibDir;

fn_lib_version_t gLibVersion = nullptr;
fn_check_version_t gCheckVersion = nullptr;
fn_start_loop_t gStartLoop = nullptr;
fn_stop_loop_t gStopLoop = nullptr;
fn_get_state_t gGetState = nullptr;
fn_get_last_error_t gGetLastError = nullptr;
fn_drain_logs_t gDrainLogs = nullptr;
fn_query_stats_t gQueryStats = nullptr;
fn_measure_t gMeasure = nullptr;
fn_free_t gFree = nullptr;

fn_hev_main_from_str_t gHevMainFromStr = nullptr;
fn_hev_quit_t gHevQuit = nullptr;
fn_hev_stats_t gHevStats = nullptr;

bool gHevRunning = false;
pthread_t gHevThread;
bool gHevThreadValid = false;
int gHevReturnCode = -1;

// --- napi helpers ----------------------------------------------------------

std::string GetStringArg(napi_env env, napi_value value) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return std::string();
    }
    std::string out;
    out.resize(len + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], len + 1, &copied) != napi_ok) {
        return std::string();
    }
    out.resize(copied);
    return out;
}

napi_value MakeString(napi_env env, const std::string &s) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

napi_value MakeBool(napi_env env, bool b) {
    napi_value v = nullptr;
    napi_get_boolean(env, b, &v);
    return v;
}

napi_value MakeInt32(napi_env env, int32_t i) {
    napi_value v = nullptr;
    napi_create_int32(env, i, &v);
    return v;
}

napi_value MakeInt64(napi_env env, int64_t i) {
    napi_value v = nullptr;
    napi_create_int64(env, i, &v);
    return v;
}

napi_value MakeUndefined(napi_env env) {
    napi_value v = nullptr;
    napi_get_undefined(env, &v);
    return v;
}

/**
 * Copies a string out of the Go library and immediately releases the Go-side
 * allocation with the Go library's own free function (never std::free).
 */
std::string TakeGoString(const char *p) {
    if (p == nullptr) {
        return std::string();
    }
    std::string out(p);
    if (gFree != nullptr) {
        gFree(p);
    }
    return out;
}

std::string ResolveLibPath(const char *name) {
    if (!gNativeLibDir.empty()) {
        return gNativeLibDir + "/" + name;
    }
    return std::string(name);
}

// --- lazy loaders ----------------------------------------------------------

bool LoadXrayLib() {
    if (gXrayHandle != nullptr) {
        return true;
    }
    std::string path = ResolveLibPath(kXrayLibName);
    void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        h = dlopen(kXrayLibName, RTLD_NOW | RTLD_LOCAL);
    }
    if (h == nullptr) {
        return false;
    }
    gGoLibLoaded = true;
    gXrayHandle = h;

    gLibVersion = reinterpret_cast<fn_lib_version_t>(dlsym(h, "V2RayOhosLibVersion"));
    gCheckVersion = reinterpret_cast<fn_check_version_t>(dlsym(h, "V2RayOhosCheckVersionX"));
    gStartLoop = reinterpret_cast<fn_start_loop_t>(dlsym(h, "V2RayOhosStartLoop"));
    gStopLoop = reinterpret_cast<fn_stop_loop_t>(dlsym(h, "V2RayOhosStopLoop"));
    gGetState = reinterpret_cast<fn_get_state_t>(dlsym(h, "V2RayOhosGetState"));
    gGetLastError = reinterpret_cast<fn_get_last_error_t>(dlsym(h, "V2RayOhosGetLastError"));
    gDrainLogs = reinterpret_cast<fn_drain_logs_t>(dlsym(h, "V2RayOhosDrainLogs"));
    gQueryStats = reinterpret_cast<fn_query_stats_t>(dlsym(h, "V2RayOhosQueryAllOutboundTrafficStats"));
    gMeasure = reinterpret_cast<fn_measure_t>(dlsym(h, "V2RayOhosMeasureOutboundDelay"));
    gFree = reinterpret_cast<fn_free_t>(dlsym(h, "V2RayOhosFree"));

    return gStartLoop != nullptr && gStopLoop != nullptr && gFree != nullptr;
}

bool LoadHevLib() {
    if (gHevHandle != nullptr) {
        return true;
    }
    std::string path = ResolveLibPath(kHevLibName);
    void *h = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        h = dlopen(kHevLibName, RTLD_NOW | RTLD_LOCAL);
    }
    if (h == nullptr) {
        return false;
    }
    gHevHandle = h;

    gHevMainFromStr = reinterpret_cast<fn_hev_main_from_str_t>(dlsym(h, "hev_socks5_tunnel_main_from_str"));
    gHevQuit = reinterpret_cast<fn_hev_quit_t>(dlsym(h, "hev_socks5_tunnel_quit"));
    gHevStats = reinterpret_cast<fn_hev_stats_t>(dlsym(h, "hev_socks5_tunnel_stats"));

    return gHevMainFromStr != nullptr && gHevQuit != nullptr;
}

} // namespace

// ---------------------------------------------------------------------------
// exported JS API
// ---------------------------------------------------------------------------

static napi_value JsXrayLibVersion(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gLibVersion == nullptr) {
        return MakeInt32(env, -1);
    }
    return MakeInt32(env, gLibVersion());
}

static napi_value JsXrayCheckVersionX(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gCheckVersion == nullptr) {
        return MakeString(env, "unavailable");
    }
    return MakeString(env, TakeGoString(gCheckVersion()));
}

static napi_value JsSetNativeLibDir(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        pthread_mutex_lock(&gLock);
        gNativeLibDir = GetStringArg(env, args[0]);
        pthread_mutex_unlock(&gLock);
    }
    return MakeUndefined(env);
}

/**
 * Sets XRAY_LOCATION_ASSET and xray.xudp.basekey.
 * Returns false when a Go core has already been loaded, because setenv() after
 * that point can crash the Go runtime (invariant 1).
 */
static napi_value JsSetCoreEnv(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MakeBool(env, false);
    }
    std::string assetDir = GetStringArg(env, args[0]);
    std::string xuKey = GetStringArg(env, args[1]);

    pthread_mutex_lock(&gLock);
    if (gGoLibLoaded) {
        pthread_mutex_unlock(&gLock);
        return MakeBool(env, false);
    }
    bool ok = true;
    if (!assetDir.empty()) {
        if (setenv("XRAY_LOCATION_ASSET", assetDir.c_str(), 1) != 0) {
            ok = false;
        }
        if (setenv("XRAY_LOCATION_CERT", assetDir.c_str(), 1) != 0) {
            ok = false;
        }
    }
    if (!xuKey.empty()) {
        if (setenv("xray.xudp.basekey", xuKey.c_str(), 1) != 0) {
            ok = false;
        }
    }
    gEnvPrepared = ok;
    pthread_mutex_unlock(&gLock);
    return MakeBool(env, ok);
}

static napi_value JsXrayStartLoop(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        return MakeString(env, "{\"success\":false,\"error\":\"missing config\"}");
    }
    std::string cfg = GetStringArg(env, args[0]);
    if (!LoadXrayLib() || gStartLoop == nullptr) {
        return MakeString(env, "{\"success\":false,\"error\":\"libv2rayohos.so not loadable\"}");
    }
    return MakeString(env, TakeGoString(gStartLoop(cfg.c_str())));
}

static napi_value JsXrayStopLoop(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gStopLoop == nullptr) {
        return MakeString(env, "{\"success\":true,\"state\":0}");
    }
    return MakeString(env, TakeGoString(gStopLoop()));
}

static napi_value JsXrayState(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gGetState == nullptr) {
        return MakeInt32(env, 0);
    }
    return MakeInt32(env, gGetState());
}

static napi_value JsXrayLastError(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gGetLastError == nullptr) {
        return MakeString(env, "");
    }
    return MakeString(env, TakeGoString(gGetLastError()));
}

static napi_value JsXrayDrainLogs(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gDrainLogs == nullptr) {
        return MakeString(env, "");
    }
    return MakeString(env, TakeGoString(gDrainLogs()));
}

static napi_value JsXrayQueryAllOutboundTrafficStats(napi_env env, napi_callback_info info) {
    if (!LoadXrayLib() || gQueryStats == nullptr) {
        return MakeString(env, "");
    }
    return MakeString(env, TakeGoString(gQueryStats()));
}

static napi_value JsXrayMeasureOutboundDelay(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MakeInt64(env, -1);
    }
    std::string cfg = GetStringArg(env, args[0]);
    std::string url = GetStringArg(env, args[1]);
    int32_t timeoutMs = 8000;
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &timeoutMs);
    }
    if (!LoadXrayLib() || gMeasure == nullptr) {
        return MakeInt64(env, -1);
    }
    return MakeInt64(env, gMeasure(cfg.c_str(), url.c_str(), timeoutMs));
}

// --- tun2socks -------------------------------------------------------------

struct HevArgs {
    std::string config;
    int tunFd;
};

static void *HevTrampoline(void *raw) {
    HevArgs *a = static_cast<HevArgs *>(raw);
    std::string cfg = a->config;
    int fd = a->tunFd;
    delete a;
    int rc = gHevMainFromStr(reinterpret_cast<const unsigned char *>(cfg.c_str()),
                             static_cast<unsigned int>(cfg.size()), fd);
    pthread_mutex_lock(&gLock);
    gHevReturnCode = rc;
    gHevRunning = false;
    gHevThreadValid = false;
    pthread_mutex_unlock(&gLock);
    return nullptr;
}

/**
 * Starts the blocking hev-socks5-tunnel loop on a detached worker thread.
 * Returns 0 when the thread was started, negative otherwise.
 */
static napi_value JsHevStart(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        return MakeInt32(env, -1);
    }
    std::string cfg = GetStringArg(env, args[0]);
    int32_t tunFd = -1;
    napi_get_value_int32(env, args[1], &tunFd);

    if (!LoadHevLib()) {
        return MakeInt32(env, -2);
    }

    pthread_mutex_lock(&gLock);
    if (gHevRunning) {
        pthread_mutex_unlock(&gLock);
        return MakeInt32(env, 0);
    }
    gHevRunning = true;
    gHevReturnCode = -1;
    pthread_mutex_unlock(&gLock);

    HevArgs *a = new HevArgs();
    a->config = cfg;
    a->tunFd = static_cast<int>(tunFd);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&gHevThread, &attr, HevTrampoline, a);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        pthread_mutex_lock(&gLock);
        gHevRunning = false;
        pthread_mutex_unlock(&gLock);
        delete a;
        return MakeInt32(env, -3);
    }
    return MakeInt32(env, 0);
}

static napi_value JsHevStop(napi_env env, napi_callback_info info) {
    pthread_mutex_lock(&gLock);
    bool running = gHevRunning;
    pthread_mutex_unlock(&gLock);
    if (!running || gHevQuit == nullptr) {
        return MakeInt32(env, 0);
    }
    gHevQuit();
    // Give the worker a moment to unwind before the caller tears the TUN down.
    for (int i = 0; i < 50; i++) {
        pthread_mutex_lock(&gLock);
        bool still = gHevRunning;
        pthread_mutex_unlock(&gLock);
        if (!still) {
            break;
        }
        usleep(20 * 1000);
    }
    return MakeInt32(env, 0);
}

static napi_value JsHevStats(napi_env env, napi_callback_info info) {
    if (!LoadHevLib() || gHevStats == nullptr) {
        return MakeString(env, "{\"txPackets\":0,\"txBytes\":0,\"rxPackets\":0,\"rxBytes\":0}");
    }
    size_t txPkts = 0, txBytes = 0, rxPkts = 0, rxBytes = 0;
    gHevStats(&txPkts, &txBytes, &rxPkts, &rxBytes);
    char buf[256];
    snprintf(buf, sizeof(buf),
             "{\"txPackets\":%zu,\"txBytes\":%zu,\"rxPackets\":%zu,\"rxBytes\":%zu}",
             txPkts, txBytes, rxPkts, rxBytes);
    return MakeString(env, std::string(buf));
}

static napi_value JsHevRunning(napi_env env, napi_callback_info info) {
    pthread_mutex_lock(&gLock);
    bool running = gHevRunning;
    pthread_mutex_unlock(&gLock);
    return MakeBool(env, running);
}

// ---------------------------------------------------------------------------
// module registration
// ---------------------------------------------------------------------------

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"xrayLibVersion", nullptr, JsXrayLibVersion, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayCheckVersionX", nullptr, JsXrayCheckVersionX, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setNativeLibDir", nullptr, JsSetNativeLibDir, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setCoreEnv", nullptr, JsSetCoreEnv, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayStartLoop", nullptr, JsXrayStartLoop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayStopLoop", nullptr, JsXrayStopLoop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayState", nullptr, JsXrayState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayLastError", nullptr, JsXrayLastError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayDrainLogs", nullptr, JsXrayDrainLogs, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"xrayQueryAllOutboundTrafficStats", nullptr, JsXrayQueryAllOutboundTrafficStats, nullptr, nullptr, nullptr,
         napi_default, nullptr},
        {"xrayMeasureOutboundDelay", nullptr, JsXrayMeasureOutboundDelay, nullptr, nullptr, nullptr, napi_default,
         nullptr},
        {"hevStart", nullptr, JsHevStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hevStop", nullptr, JsHevStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hevStats", nullptr, JsHevStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"hevRunning", nullptr, JsHevRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module gModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "v2rayngohos",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterV2rayNgOhosModule(void) {
    napi_module_register(&gModule);
}