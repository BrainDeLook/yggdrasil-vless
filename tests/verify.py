import contextlib
import http.server
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import threading
import time
import tempfile
import urllib.request
from urllib.parse import urlsplit,parse_qs,unquote

root=Path(__file__).resolve().parents[1]
script=(root/'install-ygg-vless.sh').read_text(encoding='utf-8')
blocks=re.findall(r"<<'PY'\n(.*?)\nPY", script, re.S)
for i, block in enumerate(blocks): compile(block, f'embedded-{i}', 'exec')
print(f'PASS: {len(blocks)} embedded Python programs compile')
normalizer=next(b for b in blocks if "Ошибка списка доступа:" in b)
for args,expected in [(['200:db8::1','300:db8:1:1::/64'],True),(['300:db8:1:1::1/128'],True),
                      (['200::/7'],False),(['300::/8'],False),(['300:db8:1:1::1/64'],False),
                      (['2001:db8::1'],False),(['300:db8::1%eth0'],False),([],False)]:
    r=subprocess.run([sys.executable,'-c',normalizer,*args],capture_output=True,text=True)
    assert (r.returncode==0)==expected,(args,r.stderr)
print('PASS: node IP and LAN /64 accepted; public IPv6, broad ranges and host bits rejected')
resolver=next(b for b in blocks if "Cannot determine Yggdrasil config path" in b)
for value, expected in [
    ('{ path=/usr/bin/yggdrasil ; argv[]=/usr/bin/yggdrasil -useconffile /etc/yggdrasil/yggdrasil.conf ; ignore_errors=no ; }','/etc/yggdrasil/yggdrasil.conf'),
    ('{ argv[]=/usr/bin/yggdrasil -useconffile /etc/yggdrasil.conf ; }','/etc/yggdrasil.conf'),
    ('/usr/bin/yggdrasil -useconffile="/etc/custom dir/yggdrasil.conf"','/etc/custom dir/yggdrasil.conf')]:
    r=subprocess.run([sys.executable,'-c',resolver,value],check=True,capture_output=True,text=True)
    assert r.stdout.strip()==expected
for value in ['/usr/bin/yggdrasil -autoconf', '/usr/bin/yggdrasil -useconffile $CONFIG']:
    r=subprocess.run([sys.executable,'-c',resolver,value],capture_output=True)
    assert r.returncode!=0
print('PASS: packaged/legacy/custom systemd config paths detected; ambiguous unit rejected')
scratch=tempfile.TemporaryDirectory(prefix='ygg-vless-verify-')
work=Path(scratch.name)
admin_restore=next(b for b in blocks if 'original=json.loads(raw)' in b)
for raw,expected in [
    ('{\n AdminListen: unix:///run/custom.sock # comment\n}', 'unix:///run/custom.sock'),
    ('{\n // AdminListen: unix:///wrong.sock\n AdminListen: "unix:///run/right.sock"\n}', 'unix:///run/right.sock'),
    ('{"AdminListen":"unix:///run/json.sock"}', 'unix:///run/json.sock')]:
    original=work/'original-admin.conf'; normalized=work/'normalized-admin.json'
    original.write_text(raw); normalized.write_text('{"AdminListen":""}')
    subprocess.run([sys.executable,'-c',admin_restore,str(original),str(normalized)],check=True)
    assert json.loads(normalized.read_text())['AdminListen']==expected
print('PASS: explicit admin socket retained from JSON and HJSON, ignoring comments')
def runblock(marker,args):
    code=next(b for b in blocks if marker in b)
    subprocess.run([sys.executable,'-c',code,*map(str,args)],check=True)

ygg_original=work/'ygg-original.json'; ygg_out=work/'ygg.json'
identity='ab'*64
ygg_original.write_text(json.dumps({'PrivateKey':identity,'Peers':[],'IfName':'auto','AdminListen':''}))
runblock('c=json.load(open(sys.argv[1])); peers=',[ygg_original,ygg_out])
c=json.loads(ygg_out.read_text()); assert c['PrivateKey']==identity and len(c['Peers'])==3
ygg_original.write_text(json.dumps(c)); runblock('c=json.load(open(sys.argv[1])); peers=',[ygg_original,ygg_out])
assert json.loads(ygg_out.read_text())==c
runblock('c=json.load(open(sys.argv[1])); peers=',[ygg_original,ygg_out,'tls://example.org:443'])
assert json.loads(ygg_out.read_text())['Peers']==['tls://example.org:443']
print('PASS: Yggdrasil identity/peers preserved; explicit peer override works')

base=work/'base'; temp=work/'tmp'
base.mkdir(exist_ok=True); temp.mkdir(exist_ok=True)
(base/'settings.json').unlink(missing_ok=True)
address='200:db8::1234'
runblock("base,tmp=map(pathlib.Path",[base,temp,address,'','NL / Моя нода #1'])
settings=json.loads((temp/'settings.json').read_text()); assert settings['port']==1488
(base/'settings.json').write_text(json.dumps(settings))
runblock("base,tmp=map(pathlib.Path",[base,temp,address,'2443'])
s2=json.loads((temp/'settings.json').read_text()); assert s2['uuid']==settings['uuid'] and s2['port']==2443
assert s2['reality_private_key']==settings['reality_private_key']
assert s2['reality_short_id']==settings['reality_short_id']
link=(temp/'client.txt').read_text(); assert f'@[{address}]:2443?' in link
parsed=urlsplit(link.strip()); query=parse_qs(parsed.query)
assert unquote(parsed.fragment)=='NL / Моя нода #1'
assert query['security']==['reality'] and query['pbk']==[s2['reality_public_key']]
assert query['flow']==['xtls-rprx-vision'] and 'private_key' not in link
tachyon=json.loads((temp/'client-tachyon.json').read_text())
assert tachyon['bind_interface']=='yggdrasil' and tachyon['tls']['reality']['enabled']
print('PASS: UUID/Reality keys retained, UTF-8 name encoded in link, Tachyon interface override exported')

exe=Path(os.environ['SING_BOX_BINARY']).resolve()
creationflags=subprocess.CREATE_NO_WINDOW if sys.platform=='win32' else 0
def check(p): subprocess.run([str(exe),'check','-c',str(p)],check=True)
check(temp/'server.json')
print('PASS: generated production server config accepted by sing-box 1.14.3')

def port(family=socket.AF_INET):
    with socket.socket(family) as s:
        s.bind(('::1' if family==socket.AF_INET6 else '127.0.0.1',0)); return s.getsockname()[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        payload=b'vless-domain-request-ok'
        self.send_response(200); self.end_headers(); self.wfile.write(payload)
    def log_message(self,*args): pass

http=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=http.serve_forever,daemon=True).start()
server=json.loads((temp/'server.json').read_text())
server['inbounds'][0]['listen']='::1'; server['inbounds'][0]['listen_port']=port(socket.AF_INET6)
server_file=work/'local-server.json'; server_file.write_text(json.dumps(server))
local_settings={**s2,'address':'::1','port':server['inbounds'][0]['listen_port']}
settings_file=work/'local-settings.json'; settings_file.write_text(json.dumps(local_settings))
client_file=work/'local-client.json'; client_port=port()
runblock("s=json.load(open(sys.argv[1]))",[settings_file,client_file,client_port])
check(server_file); check(client_file)
processes=[]; handles=[]
try:
    for name,config in [('server',server_file),('client',client_file)]:
        f=open(work/f'{name}.log','w'); handles.append(f)
        processes.append(subprocess.Popen([str(exe),'run','-c',str(config)],stdout=f,stderr=f,creationflags=creationflags))
    time.sleep(1)
    assert all(p.poll() is None for p in processes), 'sing-box exited'
    # A SOCKS5 domain request (ATYP=3), passed through VLESS to IPv6 server.
    def request():
        with socket.create_connection(('127.0.0.1',client_port),timeout=5) as s:
            s.settimeout(20); s.sendall(b'\x05\x01\x00'); assert s.recv(2)==b'\x05\x00'
            host=b'localhost'
            s.sendall(b'\x05\x01\x00\x03'+bytes([len(host)])+host+http.server_port.to_bytes(2,'big'))
            header=s.recv(4); assert header[1]==0,header
            n={1:4,4:16}.get(header[3])
            if n is None: n=s.recv(1)[0]
            remaining=n+2
            while remaining: remaining-=len(s.recv(remaining))
            s.sendall(b'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n')
            data=b''
            while chunk:=s.recv(65536): data+=chunk
            return data
    assert b'vless-domain-request-ok' in request()
    print('PASS: sing-box domain request -> VLESS Vision + Reality over IPv6 -> IPv4 HTTP')
    if os.environ.get('XRAY_BINARY'):
        # Build Xray settings from the share URL, as a client importer does.
        xray=Path(os.environ['XRAY_BINARY']).resolve()
        xr={'log':{'loglevel':'warning'},
            'inbounds':[{'listen':'127.0.0.1','port':port(),'protocol':'socks','settings':{'auth':'noauth'}}],
            'outbounds':[{'protocol':'vless','settings':{'vnext':[{'address':'::1',
              'port':local_settings['port'],'users':[{'id':parsed.username,'encryption':query['encryption'][0],
              'flow':query['flow'][0]}]}]},'streamSettings':{'network':'tcp','security':query['security'][0],
              'realitySettings':{'serverName':query['sni'][0],'fingerprint':query['fp'][0],
                'publicKey':query['pbk'][0],'shortId':query['sid'][0]}}}]}
        xr_file=work/'xray-client.json'; xr_file.write_text(json.dumps(xr))
        subprocess.run([str(xray),'run','-test','-config',str(xr_file)],check=True,capture_output=True)
        xf=open(work/'xray.log','w'); handles.append(xf)
        xp=subprocess.Popen([str(xray),'run','-config',str(xr_file)],stdout=xf,stderr=xf,creationflags=creationflags)
        processes.append(xp); time.sleep(.7)
        saved_port=client_port; client_port=xr['inbounds'][0]['port']
        try: assert b'vless-domain-request-ok' in request()
        finally: client_port=saved_port
        print('PASS: official Xray imports generated Reality link and transfers IPv6 VLESS traffic')
    processes[1].terminate(); processes[1].wait(timeout=5)
    bad=json.loads(client_file.read_text()); bad['outbounds'][0]['uuid']='00000000-0000-4000-8000-000000000001'
    client_file.write_text(json.dumps(bad))
    processes[1]=subprocess.Popen([str(exe),'run','-c',str(client_file)],stdout=handles[1],stderr=handles[1],creationflags=creationflags)
    time.sleep(.5)
    try:
        data=request()
    except (OSError,AssertionError,IndexError): data=b''
    assert b'vless-domain-request-ok' not in data
    print('PASS: incorrect UUID does not grant access')
finally:
    for p in processes:
        if p.poll() is None: p.terminate()
        with contextlib.suppress(subprocess.TimeoutExpired): p.wait(timeout=5)
    for f in handles: f.close()
    http.shutdown()
