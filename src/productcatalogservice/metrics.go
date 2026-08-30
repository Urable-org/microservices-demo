// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Minimal hand-rolled Prometheus text-exposition exporter (no third-party
// dependency, since go.sum for a new module can't be safely regenerated in
// this environment). Exposes the same metric names/labels the design calls
// for: productcatalog_requests_total{method,status} and
// productcatalog_request_duration_seconds{method}.

var histogramBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10}

type methodStatusKey struct {
	method string
	status string
}

type histogramData struct {
	mu      sync.Mutex
	buckets []uint64
	sum     float64
	count   uint64
}

var (
	requestCounters    sync.Map // methodStatusKey -> *uint64
	requestHistograms  sync.Map // method (string) -> *histogramData
)

func recordRequest(method, status string, duration time.Duration) {
	key := methodStatusKey{method: method, status: status}
	v, _ := requestCounters.LoadOrStore(key, new(uint64))
	atomic.AddUint64(v.(*uint64), 1)

	h, _ := requestHistograms.LoadOrStore(method, &histogramData{buckets: make([]uint64, len(histogramBuckets))})
	hd := h.(*histogramData)
	seconds := duration.Seconds()
	hd.mu.Lock()
	hd.sum += seconds
	hd.count++
	for i, b := range histogramBuckets {
		if seconds <= b {
			hd.buckets[i]++
		}
	}
	hd.mu.Unlock()
}

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")

	fmt.Fprintln(w, "# HELP productcatalog_requests_total Total number of ProductCatalogService RPCs by method and status.")
	fmt.Fprintln(w, "# TYPE productcatalog_requests_total counter")
	type counterEntry struct {
		key   methodStatusKey
		value uint64
	}
	var counters []counterEntry
	requestCounters.Range(func(k, v interface{}) bool {
		counters = append(counters, counterEntry{key: k.(methodStatusKey), value: atomic.LoadUint64(v.(*uint64))})
		return true
	})
	sort.Slice(counters, func(i, j int) bool {
		if counters[i].key.method != counters[j].key.method {
			return counters[i].key.method < counters[j].key.method
		}
		return counters[i].key.status < counters[j].key.status
	})
	for _, c := range counters {
		fmt.Fprintf(w, "productcatalog_requests_total{method=%q,status=%q} %d\n", c.key.method, c.key.status, c.value)
	}

	fmt.Fprintln(w, "# HELP productcatalog_request_duration_seconds RPC duration in seconds by method.")
	fmt.Fprintln(w, "# TYPE productcatalog_request_duration_seconds histogram")
	type histEntry struct {
		method string
		data   *histogramData
	}
	var hists []histEntry
	requestHistograms.Range(func(k, v interface{}) bool {
		hists = append(hists, histEntry{method: k.(string), data: v.(*histogramData)})
		return true
	})
	sort.Slice(hists, func(i, j int) bool { return hists[i].method < hists[j].method })
	for _, h := range hists {
		h.data.mu.Lock()
		for i, b := range histogramBuckets {
			fmt.Fprintf(w, "productcatalog_request_duration_seconds_bucket{method=%q,le=%q} %d\n", h.method, fmt.Sprintf("%g", b), h.data.buckets[i])
		}
		fmt.Fprintf(w, "productcatalog_request_duration_seconds_bucket{method=%q,le=\"+Inf\"} %d\n", h.method, h.data.count)
		fmt.Fprintf(w, "productcatalog_request_duration_seconds_sum{method=%q} %g\n", h.method, h.data.sum)
		fmt.Fprintf(w, "productcatalog_request_duration_seconds_count{method=%q} %d\n", h.method, h.data.count)
		h.data.mu.Unlock()
	}
}

func startMetricsServer(port string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/metrics", metricsHandler)
	log.Infof("starting metrics server at :%s", port)
	if err := http.ListenAndServe(fmt.Sprintf(":%s", port), mux); err != nil {
		log.Warnf("metrics server error: %v", err)
	}
}
