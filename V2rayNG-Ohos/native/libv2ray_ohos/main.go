// Package main is the HarmonyOS NEXT port of AndroidLibXrayLite.
//
// It is built as a c-shared library (libv2rayohos.so) with
//   GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1
// using an OpenHarmony-capable Go fork. See docs/OHOS_PORT.md for why that
// toolchain is mandatory (musl + TLSDESC) and for the exact recipe.
//
// Design notes vs. the Android original:
//   - gomobile/go.Seq is replaced by a flat C ABI (no Java/ArkTS bridge types).
//   - Callbacks are replaced by polling: the ArkTS side reads state, the last
//     error and the drained log buffer. cgo function-pointer callbacks across a
//     dlopen'ed c-shared library are fragile (symbol must be globally visible),
//     so they are deliberately avoided.
//   - golang.org/x/mobile/asset is gone: on HarmonyOS the geoip/geosite data
//     files are copied into the app sandbox and XRAY_LOCATION_ASSET points at
//     that directory, so plain os.Open works.
package main

/*
#include <stdint.h>
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	coreapplog "github.com/xtls/xray-core/app/log"
	corecommlog "github.com/xtls/xray-core/common/log"
	corenet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/serial"
	core "github.com/xtls/xray-core/core"
	corestats "github.com/xtls/xray-core/features/stats"
	coreserial "github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

// libVersion is the bridge ABI version. Bump on any ABI change.
const libVersion = 1

// Runtime states reported by V2RayOhosGetState.
const (
	stateStopped  = 0
	stateStarting = 1
	stateRunning  = 2
	stateError    = 3
)

const logBufferLimit = 256 * 1024

var (
	mu       sync.Mutex
	instance *core.Instance
	statsMgr corestats.Manager
	curState = stateStopped
	lastErr  string

	logMu  sync.Mutex
	logBuf strings.Builder
)

func appendLog(s string) {
	logMu.Lock()
	defer logMu.Unlock()
	logBuf.WriteString(s)
	if !strings.HasSuffix(s, "\n") {
		logBuf.WriteString("\n")
	}
	if logBuf.Len() > logBufferLimit {
		b := logBuf.String()
		logBuf.Reset()
		logBuf.WriteString(b[len(b)-logBufferLimit/2:])
	}
}

type consoleLogWriter struct{}

func (w *consoleLogWriter) Write(s string) error { appendLog(s); return nil }
func (w *consoleLogWriter) Close() error         { return nil }

func registerLogHandler() {
	_ = coreapplog.RegisterHandlerCreator(
		coreapplog.LogType_Console,
		func(lt coreapplog.LogType, options coreapplog.HandlerCreatorOptions) (corecommlog.Handler, error) {
			return corecommlog.NewLogger(func() corecommlog.Writer { return &consoleLogWriter{} }), nil
		},
	)
}

func cJSON(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		return C.CString(`{"success":false,"error":"json marshal failed"}`)
	}
	return C.CString(string(b))
}

type ack struct {
	Success bool   `json:"success"`
	Error   string `json:"error,omitempty"`
	State   int    `json:"state"`
}

// ---------------------------------------------------------------------------
// exported C ABI
// ---------------------------------------------------------------------------

// main is required by -buildmode=c-shared; the library is driven entirely
// through the exported C ABI below and never enters the Go main loop.
func main() {}

// V2RayOhosLibVersion returns the bridge ABI version.
//
//export V2RayOhosLibVersion
func V2RayOhosLibVersion() C.int { return C.int(libVersion) }

// V2RayOhosCheckVersionX returns "Lib v<N>, Xray-core v<X>".
//
//export V2RayOhosCheckVersionX
func V2RayOhosCheckVersionX() *C.char {
	return C.CString(fmt.Sprintf("Lib v%d, Xray-core v%s", libVersion, core.Version()))
}

// V2RayOhosGetState returns one of the state* constants.
//
//export V2RayOhosGetState
func V2RayOhosGetState() C.int {
	mu.Lock()
	defer mu.Unlock()
	return C.int(curState)
}

// V2RayOhosGetLastError returns the last start failure (empty when none).
//
//export V2RayOhosGetLastError
func V2RayOhosGetLastError() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return C.CString(lastErr)
}

// V2RayOhosStartLoop validates and starts the core asynchronously.
// Poll V2RayOhosGetState / V2RayOhosGetLastError for the outcome.
//
//export V2RayOhosStartLoop
func V2RayOhosStartLoop(configContent *C.char) *C.char {
	cfg := C.GoString(configContent)

	mu.Lock()
	if curState == stateRunning || curState == stateStarting {
		st := int(curState)
		mu.Unlock()
		return cJSON(ack{Success: true, State: st})
	}
	curState = stateStarting
	lastErr = ""
	mu.Unlock()

	go func() {
		if err := startCore(cfg); err != nil {
			mu.Lock()
			curState = stateError
			lastErr = err.Error()
			mu.Unlock()
			appendLog("start failed: " + err.Error())
			return
		}
		mu.Lock()
		curState = stateRunning
		lastErr = ""
		mu.Unlock()
	}()

	return cJSON(ack{Success: true, State: stateStarting})
}

// V2RayOhosStopLoop stops the core synchronously.
//
//export V2RayOhosStopLoop
func V2RayOhosStopLoop() *C.char {
	appendLog("stopping core...")

	mu.Lock()
	inst := instance
	instance = nil
	statsMgr = nil
	curState = stateStopped
	mu.Unlock()

	if inst != nil {
		if err := inst.Close(); err != nil {
			appendLog("core shutdown error: " + err.Error())
		}
	}
	appendLog("Core stopped")
	return cJSON(ack{Success: true, State: stateStopped})
}

// V2RayOhosDrainLogs returns and clears the accumulated core log text.
//
//export V2RayOhosDrainLogs
func V2RayOhosDrainLogs() *C.char {
	logMu.Lock()
	defer logMu.Unlock()
	out := logBuf.String()
	logBuf.Reset()
	return C.CString(out)
}

// V2RayOhosMeasureOutboundDelay builds a throwaway core from the given config
// and measures the delay of a real request to testUrl. Returns milliseconds,
// or a negative value on failure.
//
//export V2RayOhosMeasureOutboundDelay
func V2RayOhosMeasureOutboundDelay(configContent *C.char, testURL *C.char, timeoutMs C.int) C.int64_t {
	cfg := C.GoString(configContent)
	url := C.GoString(testURL)
	timeout := time.Duration(int(timeoutMs)) * time.Millisecond
	if timeout <= 0 {
		timeout = 8 * time.Second
	}
	ms, err := measureDelay(cfg, url, timeout)
	if err != nil {
		appendLog("delay test failed: " + err.Error())
		return C.int64_t(-1)
	}
	return C.int64_t(ms)
}

// V2RayOhosFree releases a string allocated by this library.
//
//export V2RayOhosFree
func V2RayOhosFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// V2RayOhosQueryAllOutboundTrafficStats retrieves and resets all outbound
// traffic counters. Mirrors AndroidLibXrayLite's CoreController method:
// returns "tag,direction,value;tag,direction,value;".
//
//export V2RayOhosQueryAllOutboundTrafficStats
func V2RayOhosQueryAllOutboundTrafficStats() *C.char {
	mu.Lock()
	sm := statsMgr
	mu.Unlock()
	if sm == nil {
		return C.CString("")
	}

	var b strings.Builder
	sm.VisitCounters(func(name string, counter corestats.Counter) bool {
		parts := strings.Split(name, ">>>")
		if len(parts) != 4 || parts[0] != "outbound" || parts[2] != "traffic" {
			return true
		}
		value := counter.Set(0)
		if value <= 0 {
			return true
		}
		b.WriteString(parts[1])
		b.WriteByte(',')
		b.WriteString(parts[3])
		b.WriteByte(',')
		b.WriteString(strconv.FormatInt(value, 10))
		b.WriteByte(';')
		return true
	})
	return C.CString(b.String())
}

// ---------------------------------------------------------------------------
// internals
// ---------------------------------------------------------------------------

func startCore(configContent string) error {
	appendLog("initializing core...")

	config, err := coreserial.LoadJSONConfig(strings.NewReader(configContent))
	if err != nil {
		return fmt.Errorf("config error: %w", err)
	}

	inst, err := core.New(config)
	if err != nil {
		return fmt.Errorf("core init failed: %w", err)
	}

	sm, _ := inst.GetFeature(corestats.ManagerType()).(corestats.Manager)

	appendLog("starting core...")
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return fmt.Errorf("startup failed: %w", err)
	}

	mu.Lock()
	instance = inst
	statsMgr = sm
	mu.Unlock()

	appendLog("Started successfully, running")
	return nil
}

// measureDelay ports AndroidLibXrayLite's MeasureOutboundDelay: it builds a
// throwaway instance that keeps only the outbound/dispatcher/log apps, then
// dials testURL through the core instance.
func measureDelay(configContent, testURL string, timeout time.Duration) (int64, error) {
	config, err := coreserial.LoadJSONConfig(strings.NewReader(configContent))
	if err != nil {
		return -1, fmt.Errorf("config load error: %w", err)
	}

	config.Inbound = nil
	var essentialApp []*serial.TypedMessage
	for _, app := range config.App {
		if app.Type == "xray.app.proxyman.OutboundConfig" ||
			app.Type == "xray.app.dispatcher.Config" ||
			app.Type == "xray.app.log.Config" {
			essentialApp = append(essentialApp, app)
		}
	}
	config.App = essentialApp

	inst, err := core.New(config)
	if err != nil {
		return -1, fmt.Errorf("instance creation failed: %w", err)
	}
	if err := inst.Start(); err != nil {
		_ = inst.Close()
		return -1, fmt.Errorf("startup failed: %w", err)
	}
	defer func() { _ = inst.Close() }()

	if timeout <= 0 {
		timeout = 12 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	return measureInstDelay(ctx, inst, testURL)
}

func measureInstDelay(ctx context.Context, inst *core.Instance, url string) (int64, error) {
	if inst == nil {
		return -1, errors.New("core instance is nil")
	}
	if url == "" {
		url = "https://www.google.com/generate_204"
	}

	tr := &http.Transport{
		TLSHandshakeTimeout: 6 * time.Second,
		DisableKeepAlives:   false,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dest, err := corenet.ParseDestination(fmt.Sprintf("%s:%s", network, addr))
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, inst, dest)
		},
	}
	defer tr.CloseIdleConnections()

	client := &http.Client{Transport: tr, Timeout: 12 * time.Second}

	var minDuration int64 = -1
	success := false
	var lastErr error

	const attempts = 2
	for i := 0; i < attempts; i++ {
		select {
		case <-ctx.Done():
			if !success {
				return -1, ctx.Err()
			}
			return minDuration, nil
		default:
		}

		req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
		if err != nil {
			lastErr = fmt.Errorf("failed to create HTTP request: %w", err)
			continue
		}

		start := time.Now()
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}

		_, err = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()

		if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
			lastErr = fmt.Errorf("invalid status: %s", resp.Status)
			continue
		}
		if err != nil {
			lastErr = fmt.Errorf("failed to read response body: %w", err)
			continue
		}

		duration := time.Since(start).Milliseconds()
		if !success || duration < minDuration {
			minDuration = duration
		}
		success = true
	}

	if !success {
		if lastErr == nil {
			lastErr = errors.New("delay test failed")
		}
		return -1, lastErr
	}
	return minDuration, nil
}
