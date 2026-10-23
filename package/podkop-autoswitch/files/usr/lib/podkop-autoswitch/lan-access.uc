// SPDX-License-Identifier: GPL-2.0-or-later
// CGI REMOTE_ADDR and netifd state, never forwarded headers or client-supplied CIDR.
import { readfile } from 'fs';
function ip(s) {
    if (type(s) != 'string') return null;
    s = lc(split(s, '%')[0]);
    if (index(s, ':') < 0) {
        let parts = split(s, '.');
        if (length(parts) != 4) return null;
        let bytes = [];
        for (let p in parts) {
            if (!match(p, /^[0-9]{1,3}$/) || int(p) > 255) return null;
            push(bytes, int(p));
        }
        return bytes;
    }
    // Convert embedded IPv4 (including ::ffff:192.0.2.1) before expanding ::.
    if (index(s, '.') >= 0) {
        let pos = rindex(s, ':'), tail = ip(substr(s, pos + 1));
        if (!tail || length(tail) != 4) return null;
        s = substr(s, 0, pos + 1) + sprintf('%x:%x', tail[0] * 256 + tail[1], tail[2] * 256 + tail[3]);
    }
    let halves = split(s, '::');
    if (length(halves) > 2) return null;
    let a = halves[0] == '' ? [] : split(halves[0], ':');
    let b = length(halves) == 1 || halves[1] == '' ? [] : split(halves[1], ':');
    let fill = 8 - length(a) - length(b);
    if (fill < 0 || (length(halves) == 1 && fill != 0) || (length(halves) == 2 && fill == 0)) return null;
    if (length(halves) == 2) for (let i = 0; i < fill; i++) push(a, '0');
    for (let part in b) push(a, part);
    let bytes = [];
    for (let part in a) {
        if (!match(part, /^[a-f0-9]{1,4}$/)) return null;
        let n = int(part, 16); push(bytes, n >> 8, n & 255);
    }
    if (length(bytes) == 16 && join(',', slice(bytes, 0, 12)) == '0,0,0,0,0,0,0,0,0,0,255,255') return slice(bytes, 12);
    return bytes;
}
function contains(client, address, prefix) {
    let network = ip(address);
    if (!client || !network || length(client) != length(network) || prefix < 1 || prefix > length(network) * 8) return false;
    for (let i = 0; prefix > 0; i++) {
        let bits = prefix > 8 ? 8 : prefix, mask = (255 << (8 - bits)) & 255;
        if ((client[i] & mask) != (network[i] & mask)) return false;
        prefix -= bits;
    }
    return true;
}
let client = ip(ARGV[0]), host = lc(ARGV[1] || ''), networks = split(ARGV[2] || 'lan', ' ');
let router = lc(ARGV[3] || ''), domain = lc(ARGV[4] || 'lan');
if (substr(host, 0, 1) == '[') host = split(substr(host, 1), ']')[0];
else host = split(host, ':')[0];
let data = json(readfile('/dev/stdin'));
let allowed = false, hostAllowed = router != '' && (host == router || host == router + '.' + domain || host == router + '.local');
for (let iface in data.interface || []) {
    if (index(networks, iface.interface) < 0 || !iface.up) continue;
    let addresses = [];
    for (let item in iface['ipv4-address'] || []) push(addresses, item);
    for (let item in iface['ipv6-address'] || []) push(addresses, item);
    for (let item in iface['ipv6-prefix-assignment'] || []) if (item['local-address']) push(addresses, item['local-address']);
    for (let item in addresses) {
        // A link-local subnet also exists on WAN; don't authorize it here.
        if (match(lc(item.address), /^fe[89ab]/)) continue;
        if (contains(client, item.address, int(item.mask))) allowed = true;
        let hostIp = ip(host), addressIp = ip(item.address);
        if (hostIp && addressIp && join(',', hostIp) == join(',', addressIp)) hostAllowed = true;
    }
}
exit(allowed && hostAllowed ? 0 : 1);
