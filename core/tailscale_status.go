//go:build with_gvisor && !no_tailscale

package main

import (
	"context"
	"encoding/json"
	"reflect"
	"sort"
	"strings"
	"time"

	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/tailscale/ipn/ipnstate"
	"github.com/metacubex/tailscale/tsnet"
)

type tailscalePeer struct {
	Name           string   `json:"name"`
	DNSName        string   `json:"dnsName,omitempty"`
	OS             string   `json:"os,omitempty"`
	IPs            []string `json:"ips,omitempty"`
	Routes         []string `json:"routes,omitempty"` // subnet routes it serves
	Online         bool     `json:"online"`
	ExitNode       bool     `json:"exitNode,omitempty"` // the exit node in use
	ExitNodeOption bool     `json:"exitNodeOption,omitempty"`
	Direct         bool     `json:"direct,omitempty"`
	Relay          string   `json:"relay,omitempty"` // DERP region
	RxBytes        int64    `json:"rxBytes,omitempty"`
	TxBytes        int64    `json:"txBytes,omitempty"`
}

type tailscaleStatus struct {
	State   string          `json:"state"`
	Tailnet string          `json:"tailnet,omitempty"`
	Self    *tailscalePeer  `json:"self,omitempty"`
	Peers   []tailscalePeer `json:"peers,omitempty"`
	Health  []string        `json:"health,omitempty"`
}

// handleGetTailscaleStatus summarizes the app's node, "" if there is none.
// The node only starts on first use, so before that the state is NotStarted.
func handleGetTailscaleStatus(fn func(value string)) {
	go func() {
		name, _ := appTailscaleProxy.Load().(string)
		if name == "" {
			fn("")
			return
		}
		status := tailscaleStatus{State: "NotStarted"}
		if server := appTailscaleServer(name); server != nil {
			st, err := queryTailscaleStatus(server)
			if err != nil {
				status = tailscaleStatus{State: "Error", Health: []string{err.Error()}}
			} else {
				status = summarizeTailscaleStatus(st)
			}
		}
		data, _ := json.Marshal(status)
		fn(string(data))
	}()
}

// appTailscaleServer returns the node's tsnet server once the outbound has
// started it: starting it here would bypass the outbound, which then could
// not close it on reload. Both fields are private to the kernel's outbound.
func appTailscaleServer(name string) *tsnet.Server {
	p := tunnel.Proxies()[name]
	if p == nil || p.Type() != constant.Tailscale {
		return nil
	}
	started := findFieldByName(reflect.ValueOf(p), "serverStarted")
	server := findFieldByName(reflect.ValueOf(p), "server")
	if !started.IsValid() || started.Kind() != reflect.Bool || !started.Bool() ||
		!server.IsValid() || server.Type() != reflect.TypeOf((*tsnet.Server)(nil)) || server.IsNil() {
		return nil
	}
	return (*tsnet.Server)(server.UnsafePointer())
}

func queryTailscaleStatus(server *tsnet.Server) (*ipnstate.Status, error) {
	lc, err := server.LocalClient()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	return lc.Status(ctx)
}

func summarizeTailscaleStatus(st *ipnstate.Status) tailscaleStatus {
	status := tailscaleStatus{State: st.BackendState, Health: st.Health}
	if st.CurrentTailnet != nil {
		status.Tailnet = st.CurrentTailnet.Name
	}
	if st.Self != nil {
		self := tailscalePeerOf(st.Self)
		status.Self = &self
	}
	for _, p := range st.Peer {
		status.Peers = append(status.Peers, tailscalePeerOf(p))
	}
	sort.Slice(status.Peers, func(i, j int) bool {
		a, b := status.Peers[i], status.Peers[j]
		if a.Online != b.Online {
			return a.Online
		}
		return a.Name < b.Name
	})
	return status
}

func tailscalePeerOf(p *ipnstate.PeerStatus) tailscalePeer {
	peer := tailscalePeer{
		Name:           p.HostName,
		DNSName:        strings.TrimSuffix(p.DNSName, "."),
		OS:             p.OS,
		Online:         p.Online,
		ExitNode:       p.ExitNode,
		ExitNodeOption: p.ExitNodeOption,
		Direct:         p.CurAddr != "",
		Relay:          p.Relay,
		RxBytes:        p.RxBytes,
		TxBytes:        p.TxBytes,
	}
	for _, ip := range p.TailscaleIPs {
		peer.IPs = append(peer.IPs, ip.String())
	}
	if p.PrimaryRoutes != nil {
		for i := 0; i < p.PrimaryRoutes.Len(); i++ {
			peer.Routes = append(peer.Routes, p.PrimaryRoutes.At(i).String())
		}
	}
	return peer
}
