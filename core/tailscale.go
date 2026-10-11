package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

// Parent of the per-network node state dirs; must match tailscaleStateDir in
// lib/common/tailscale.dart.
const tailscaleStateDir = "bettbox-tailscale"

// Name of the app's Tailscale proxy in the applied config ("" if none).
var appTailscaleProxy atomic.Value

// closeTailscaleProxies stops the running tsnet nodes. Replaced proxies are
// otherwise only closed by GC finalizers, so a reload could run two nodes on
// the same state dir.
func closeTailscaleProxies() {
	seen := map[constant.Proxy]struct{}{}
	closeProxy := func(p constant.Proxy) {
		if p == nil || p.Type() != constant.Tailscale {
			return
		}
		if _, ok := seen[p]; ok {
			return
		}
		seen[p] = struct{}{}
		_ = p.Close()
	}
	for _, p := range tunnel.Proxies() {
		closeProxy(p)
	}
	for _, pd := range tunnel.Providers() {
		for _, p := range pd.Proxies() {
			closeProxy(p)
		}
	}
}

// resetTailscaleState forgets a node identity by deleting its state dir,
// which must be inside tailscaleStateDir.
func resetTailscaleState(dir string) {
	root := constant.Path.Resolve(tailscaleStateDir)
	dir = constant.Path.Resolve(dir)
	if !strings.HasPrefix(dir, root+string(filepath.Separator)) {
		log.Warnln("[Tailscale] refusing to reset %s", dir)
		return
	}
	closeTailscaleProxies()
	if err := os.RemoveAll(dir); err != nil {
		log.Warnln("[Tailscale] reset state: %v", err)
	}
}

// notifyTailscaleAuth forwards tsnet's login URL, which it only logs at info
// level, so the app can show it whatever the log level is.
func notifyTailscaleAuth(payload string) {
	name, _ := appTailscaleProxy.Load().(string)
	if name == "" || !strings.HasPrefix(payload, "[Tailscale]("+name+") ") {
		return // not the app's node, e.g. a profile's own tailscale proxy
	}
	url := ""
	if _, after, ok := strings.Cut(payload, " go to: "); ok {
		url = strings.TrimSpace(after)
	} else if !strings.Contains(payload, "AuthLoop: state is ") {
		return
	}
	sendMessage(Message{Type: TailscaleAuthMessage, Data: url})
}

// resolveTailscaleByPolicy makes the app's Tailscale proxy resolve hosts under
// the tailnet DNS domains with mihomo's DNS, whose nameserver-policy sends
// them to DNS servers inside the tailnet (<ip>#<name>). The native outbound
// would re-resolve them via MagicDNS only; other hosts keep that path.
func resolveTailscaleByPolicy(proxies map[string]constant.Proxy, name string, domains []string) {
	if p, ok := proxies[name]; ok && p.Type() == constant.Tailscale && len(domains) > 0 {
		proxies[name] = adapter.NewProxy(policyResolving{p.Adapter(), domains})
	}
}

type policyResolving struct {
	constant.ProxyAdapter
	domains []string
}

func (p policyResolving) DialContext(ctx context.Context, metadata *constant.Metadata) (constant.Conn, error) {
	metadata, err := p.resolveHost(ctx, metadata)
	if err != nil {
		return nil, err
	}
	return p.ProxyAdapter.DialContext(ctx, metadata)
}

func (p policyResolving) ListenPacketContext(ctx context.Context, metadata *constant.Metadata) (constant.PacketConn, error) {
	metadata, err := p.resolveHost(ctx, metadata)
	if err != nil {
		return nil, err
	}
	pc, err := p.ProxyAdapter.ListenPacketContext(ctx, metadata)
	if err != nil {
		return nil, err
	}
	return policyResolvingPacketConn{pc, p}, nil
}

func (p policyResolving) covers(host string) bool {
	for _, domain := range p.domains {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return true
		}
	}
	return false
}

// resolveHost returns IP-addressed metadata for covered hosts, resolving them
// through mihomo's DNS if needed, so the outbound does not re-resolve them.
func (p policyResolving) resolveHost(ctx context.Context, metadata *constant.Metadata) (*constant.Metadata, error) {
	if metadata.Host == "" || !p.covers(metadata.Host) {
		return metadata, nil
	}
	resolved := metadata.Clone()
	if !resolved.Resolved() {
		ip, err := resolver.ResolveIP(ctx, resolved.Host)
		if err != nil {
			return nil, err
		}
		resolved.DstIP = ip
	}
	resolved.Host = ""
	return resolved, nil
}

type policyResolvingPacketConn struct {
	constant.PacketConn
	policy policyResolving
}

func (pc policyResolvingPacketConn) ResolveUDP(ctx context.Context, metadata *constant.Metadata) error {
	if !pc.policy.covers(metadata.Host) {
		return pc.PacketConn.ResolveUDP(ctx, metadata)
	}
	if metadata.Resolved() {
		return nil
	}
	ip, err := resolver.ResolveIP(ctx, metadata.Host)
	if err != nil {
		return err
	}
	metadata.DstIP = ip
	return nil
}
