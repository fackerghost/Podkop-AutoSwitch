import base64
import json
from pathlib import Path

p = Path(__file__).parent / 'fixtures'
p.mkdir(exist_ok=True)
vmess = {'v': '2', 'ps': 'Test VMess', 'add': 'example.com', 'port': '443',
         'id': '00000000-0000-0000-0000-000000000001', 'aid': '0', 'net': 'ws',
         'type': 'none', 'host': 'example.com', 'path': '/ws', 'tls': 'tls', 'sni': 'example.com'}
lines = [
    'vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls&type=ws&path=%2Fws&sni=example.com#VLESS',
    'vmess://' + base64.b64encode(json.dumps(vmess).encode()).decode(),
    'trojan://test%3Apassword@example.com:443?security=tls&sni=example.com#Trojan',
    'ss://' + base64.b64encode(b'aes-128-gcm:test-password').decode() + '@example.com:443#Shadowsocks',
    'hy2://test-password@example.com:443?sni=example.com#Hysteria2',
    'tuic://00000000-0000-0000-0000-000000000001:test-password@example.com:443?alpn=h3&congestion_control=bbr#TUIC',
]
(p / 'protocols.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')
