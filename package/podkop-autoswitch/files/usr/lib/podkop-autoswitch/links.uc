// SPDX-License-Identifier: GPL-2.0-or-later
// OpenWrt's jq may be built without regex. ucode handles URI parsing byte-safely.
import { readfile } from 'fs';
function decode(s) {
    if (index(replace(s, /%[0-9a-fA-F]{2}/g, ''), '%') >= 0) die('Invalid percent escape');
    return replace(s, /%[0-9a-fA-F]{2}/g, function(m) { return chr(int(substr(m, 1), 16)); });
}
function base64(s) {
    s = replace(replace(replace(s, /\s/g, ''), /-/g, '+'), /_/g, '/');
    while (length(s) % 4) s += '=';
    let out = b64dec(s);
    if (out == null) die('Invalid base64');
    return out;
}
function flag(s) {
    if (s == null || s == '' || s == '0' || s == 'false') return false;
    if (s == '1' || s == 'true') return true;
    die('Invalid boolean');
}
function merge(a, b) { for (let k in b) a[k] = b[k]; return a; }
function tls(q, fallback) {
    let security = q.security ?? fallback;
    if (security == 'none' || security == '') return {};
    if (security != 'tls' && security != 'reality') die('Unsupported TLS security');
    let t = { enabled: true };
    if (q.sni || q.peer) t.server_name = q.sni || q.peer;
    if (q.alpn) t.alpn = split(q.alpn, ',');
    if (q.fp) t.utls = { enabled: true, fingerprint: q.fp };
    if (flag(q.allowInsecure ?? q.insecure)) t.insecure = true;
    if (security == 'reality') {
        if (!q.pbk) die('Missing Reality public key');
        t.reality = { enabled: true, public_key: q.pbk, short_id: q.sid || '' };
    }
    return { tls: t };
}
function transport(q) {
    let type = q.type || 'tcp', t;
    if (type == 'tcp' && (!q.headerType || q.headerType == 'none')) return {};
    if (type == 'ws') {
        t = { type: 'ws', path: q.path || '/' };
        if (q.host) t.headers = { Host: q.host };
    } else if (type == 'grpc') t = { type: 'grpc', service_name: q.serviceName || '' };
    else if (type == 'http' || type == 'h2') {
        t = { type: 'http', path: q.path || '/' };
        if (q.host) t.host = split(q.host, ',');
    } else if (type == 'httpupgrade') t = { type: type, path: q.path || '/', host: q.host || '' };
    else die('Unsupported transport; use native sing-box JSON');
    return { transport: t };
}
function parse_link(line) {
    let m = match(line, /^([a-zA-Z0-9]+):\/\/(.*)$/);
    if (!m) die('Invalid URI');
    let scheme = lc(m[1]), body = m[2];
    if (scheme == 'vmess') {
        let v = json(base64(body));
        if (type(v) != 'object') die('Invalid VMess JSON');
        if (v.type && v.type != 'none') die('Unsupported VMess header');
        let o = { type: 'vmess', tag: v.ps || 'VMess', server: v.add, server_port: int(v.port),
            uuid: v.id, security: v.scy || 'auto', alter_id: int(v.aid || 0) };
        merge(o, tls({ security: v.tls || 'none', sni: v.sni || v.host, alpn: v.alpn, fp: v.fp, allowInsecure: v.allowInsecure }, 'none'));
        return merge(o, transport({ type: v.net || 'tcp', path: v.path, host: v.host, serviceName: v.path }));
    }
    let fragment = index(body, '#'), label = '';
    if (fragment >= 0) { label = decode(substr(body, fragment + 1)); body = substr(body, 0, fragment); }
    let question = index(body, '?'), q = {};
    if (question >= 0) {
        for (let pair in split(substr(body, question + 1), '&')) {
            if (!pair) continue;
            let eq = index(pair, '='), key = decode(eq < 0 ? pair : substr(pair, 0, eq));
            if (key in q) die('Duplicate URI option');
            q[key] = eq < 0 ? '' : decode(substr(pair, eq + 1));
        }
        body = substr(body, 0, question);
    }
    let allowed = ['security','sni','peer','alpn','fp','pbk','sid','type','host','path','serviceName',
      'headerType','flow','packetEncoding','allowInsecure','insecure','obfs','obfs-password',
      'upmbps','downmbps','congestion_control','udp_relay_mode','disable_sni','heartbeat','encryption'];
    for (let key in q) if (index(allowed, key) < 0) die('Unsupported URI option: ' + key);
    if (scheme == 'ss' && index(body, '@') < 0) body = base64(body);
    m = match(body, /^(.*)@(\[[^]]+\]|[^:]+):([0-9]+)\/?$/);
    if (!m) die('Invalid authority/port');
    let user = decode(m[1]), host = m[2];
    if (substr(host, 0, 1) == '[') host = substr(host, 1, length(host) - 2);
    let o = { server: host, server_port: int(m[3]), tag: label || scheme };
    if (scheme == 'vless') {
        if (q.encryption && q.encryption != 'none') die('Unsupported VLESS encryption');
        o.type = 'vless'; o.uuid = user;
        if (q.flow) o.flow = q.flow;
        if (q.packetEncoding) o.packet_encoding = q.packetEncoding;
        merge(o, tls(q, 'none')); merge(o, transport(q));
    } else if (scheme == 'trojan') {
        o.type = 'trojan'; o.password = user;
        merge(o, tls(q, 'tls')); merge(o, transport(q));
    } else if (scheme == 'ss') {
        if (index(user, ':') < 0) user = base64(user);
        let colon = index(user, ':');
        if (colon < 1) die('Invalid Shadowsocks credentials');
        o.type = 'shadowsocks'; o.method = substr(user, 0, colon); o.password = substr(user, colon + 1);
    } else if (scheme == 'hy2' || scheme == 'hysteria2') {
        o.type = 'hysteria2'; o.password = user; merge(o, tls(q, 'tls'));
        if (q.obfs) o.obfs = { type: q.obfs, password: q['obfs-password'] || '' };
        if (q.upmbps) o.up_mbps = int(q.upmbps);
        if (q.downmbps) o.down_mbps = int(q.downmbps);
    } else if (scheme == 'tuic') {
        let colon = index(user, ':');
        if (colon < 1) die('Invalid TUIC credentials');
        o.type = 'tuic'; o.uuid = substr(user, 0, colon); o.password = substr(user, colon + 1);
        merge(o, tls(q, 'tls'));
        if (q.congestion_control) o.congestion_control = q.congestion_control;
        if (q.udp_relay_mode) o.udp_relay_mode = q.udp_relay_mode;
        if (q.disable_sni) o.tls.disable_sni = flag(q.disable_sni);
        if (q.heartbeat) o.heartbeat = q.heartbeat;
    } else if (scheme == 'socks5' || scheme == 'http') {
        let colon = index(user, ':');
        o.type = scheme == 'socks5' ? 'socks' : 'http';
        o.username = colon < 0 ? user : substr(user, 0, colon);
        o.password = colon < 0 ? '' : substr(user, colon + 1);
        if (scheme == 'socks5') o.version = '5';
    } else die('Unsupported URI scheme; use native sing-box JSON');
    return o;
}
let data = readfile(ARGV[0]);
if (data == null) die('Cannot read subscription');
if (index(data, '://') < 0) data = base64(data);
let count = 0;
for (let line in split(data, '\n')) {
    line = trim(line);
    if (!line || substr(line, 0, 1) == '#') continue;
    if (++count > int(ARGV[1] || '64')) die('Too many nodes');
    try { printf('%J\n', parse_link(line)); }
    catch (e) { die(sprintf('URI %d: %s', count, e.message || 'parse failed')); }
}
if (!count) die('Empty subscription');
