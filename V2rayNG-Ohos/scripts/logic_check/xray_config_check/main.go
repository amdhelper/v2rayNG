// Command xray_config_check feeds every generated config in ../out through the
// pinned xray-core, using exactly the two calls the shipped bridge makes
// (serial.LoadJSONConfig then core.New). Anything the core refuses would have
// failed the whole connection on the device, so this is the gate that catches
// "the generator produced something the consumer will not accept".
//
// It also enforces the deliberate entries in out/expected_failures.json: those
// must fail with the documented reason, otherwise a claim in
// docs/OHOS_PORT.md §6 has silently stopped being true.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	core "github.com/xtls/xray-core/core"
	coreserial "github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

// shape mirrors just enough of the xray config schema to reject vacuous input.
type shape struct {
	Outbounds []json.RawMessage `json:"outbounds"`
}

func build(path string) error {
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	// Guard against a vacuous pass: a fragment (or an empty object) parses as an
	// xray config with no outbounds, and core.New succeeds on it. That would make
	// the whole check silently meaningless, so require a real outbound list.
	var sh shape
	if err := json.Unmarshal(raw, &sh); err != nil {
		return fmt.Errorf("shape: %w", err)
	}
	if len(sh.Outbounds) == 0 {
		return fmt.Errorf("shape: no outbounds — this is not a complete config (fragments belong in out-fragments/)")
	}
	cfg, err := coreserial.LoadJSONConfig(strings.NewReader(string(raw)))
	if err != nil {
		return fmt.Errorf("load: %w", err)
	}
	inst, err := core.New(cfg)
	if err != nil {
		return fmt.Errorf("build: %w", err)
	}
	return inst.Close()
}

// resolveAssetDir points xray at the port's own geoip/geosite data.
//
// This mirrors what the shipped VPN ability does before the first dlopen
// (CoreNative.setCoreEnv -> setenv XRAY_LOCATION_ASSET): without it, any config
// that uses geoip:/geosite: routing rules fails to build, and the failure takes
// the WHOLE config down, not just the rule.
func resolveAssetDir() string {
	if v := os.Getenv("XRAY_LOCATION_ASSET"); v != "" {
		return v
	}
	wd, err := os.Getwd()
	if err != nil {
		return ""
	}
	// out/ is run from scripts/logic_check[/xray_config_check]; try both.
	for _, rel := range []string{"../../entry/src/main/resources/rawfile", "../../../entry/src/main/resources/rawfile"} {
		cand := filepath.Clean(filepath.Join(wd, rel))
		if _, err := os.Stat(filepath.Join(cand, "geoip.dat")); err == nil {
			os.Setenv("XRAY_LOCATION_ASSET", cand)
			return cand
		}
	}
	return ""
}

func main() {
	asset := resolveAssetDir()
	if asset == "" {
		fmt.Println("FATAL: geoip.dat/geosite.dat not found; run scripts/sync_geo_assets.sh first")
		fmt.Println("       (configs with geoip:/geosite: routing rules cannot build without them)")
		os.Exit(2)
	}
	fmt.Printf("xray_config_check: XRAY_LOCATION_ASSET=%s\n", asset)

	dir := "out"
	if len(os.Args) > 1 {
		dir = os.Args[1]
	}

	expected := map[string]string{}
	if raw, err := os.ReadFile(filepath.Join(dir, "expected_failures.json")); err == nil {
		if err := json.Unmarshal(raw, &expected); err != nil {
			fmt.Printf("FATAL: expected_failures.json is not valid JSON: %v\n", err)
			os.Exit(2)
		}
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Printf("FATAL: cannot read %s: %v\n", dir, err)
		os.Exit(2)
	}

	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".json") && e.Name() != "expected_failures.json" {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)
	if len(files) == 0 {
		fmt.Printf("FATAL: no configs in %s — did run.mjs emit them?\n", dir)
		os.Exit(2)
	}

	fmt.Printf("xray_config_check: core %s, %d configs\n", core.Version(), len(files))

	bad := 0
	for _, name := range files {
		err := build(filepath.Join(dir, name))
		reason, mustFail := expected[name]

		switch {
		case mustFail && err == nil:
			fmt.Printf("  FAIL %-40s expected it to be rejected (%s) but it built\n", name, reason)
			bad++
		case mustFail && err != nil:
			if !strings.Contains(err.Error(), reason) {
				fmt.Printf("  FAIL %-40s rejected, but not for the documented reason %q: %v\n", name, reason, err)
				bad++
			} else {
				fmt.Printf("  ok   %-40s rejected as documented (%s)\n", name, reason)
			}
		case err != nil:
			fmt.Printf("  FAIL %-40s %v\n", name, err)
			bad++
		default:
			fmt.Printf("  ok   %-40s\n", name)
		}
	}

	total := len(files) - len(expected)
	fmt.Printf("xray_config_check: %d expected-pass, %d expected-fail, %d problem(s)\n", total, len(expected), bad)
	if bad > 0 {
		os.Exit(1)
	}
	fmt.Println("xray_config_check: OK")
}
