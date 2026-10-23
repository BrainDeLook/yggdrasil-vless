"""Exercise the actual Bash wizard through a pseudo-terminal, without installing anything."""
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time

source=(Path(__file__).resolve().parents[1]/'install-ygg-vless.sh').read_text()
wizard=source[source.index('normalize_access() {'):source.index('detect_ygg_config() {')]
styles=source[source.index("C_RESET=''"):source.index('log() {')]
with tempfile.TemporaryDirectory(prefix='ygg-wizard-') as d:
    script=Path(d)/'wizard.sh'
    script.write_text('set -eu\nexec 3>&1\n'+styles+'\nBASE='+d+'\nNODE_NAME=""\nPORT=""\nREALITY_SERVER=""\nALLOW_IPS=()\nASSUME_YES=0\nINSTALLER_VERSION=test\ndie(){ echo "$*"; exit 1; }\n'+wizard+'\nconfigure_wizard\nprintf "RESULT:%s:%s\\n" "$NODE_NAME" "$PORT"\n')
    primary,secondary=pty.openpty()
    # Simulate blank lines left by pasting the shell launch command.
    os.write(primary,b'\n\n\n')
    p=subprocess.Popen(['bash',str(script)],stdin=secondary,stdout=secondary,stderr=secondary,env={k:v for k,v in dict(os.environ,TERM='xterm-256color').items() if k!='NO_COLOR'})
    os.close(secondary)
    data=b''
    try:
        responses=[('Название подключения','Моя нода NL\n'),
                   ('Порт прокси','неверный-порт\n'),
                   ('Введите целое число','2443\n'),
                   ('IPv6 роутера (без /7)','\n'),
                   ('Это обязательное поле','300:1111:2222:3333::/64\n'),
                   ('Ошибка списка доступа','200:1111:2222:3333:4444:5555:6666:7777\n'),
                   ('Подсеть LAN IPv6-PD (с /64)','\n'),
                   ('Подсеть LAN IPv6-PD (с /64)','300:1111:2222:3333::/64\n')]
        next_response=0
        response_offset=0
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            if select.select([primary],[],[],.1)[0]:
                try: chunk=os.read(primary,65536)
                except OSError: break
                if not chunk: break
                data+=chunk
                if next_response<len(responses):
                    trigger,response=responses[next_response]
                    if trigger.encode() in data[response_offset:]:
                        os.write(primary,response.encode())
                        next_response+=1
                        response_offset=len(data)
            elif p.poll() is not None: break
        p.wait(timeout=2)
        output=data.decode(errors='replace')
        assert p.returncode==0,output
        assert '\x1b[36m' in output and '\x1b[33m' in output and '\x1b[0m' in output,output
        assert 'Название подключения' in output and 'Введите целое число' in output,output
        assert 'Ошибка списка доступа' in output and 'IPv6-PD' in output,output
        assert 'RESULT:Моя нода NL:2443' in output,output
        assert next_response==len(responses),output
        print('PASS: router and LAN fields are mandatory and reject swapped values; queued blank lines do not skip name; interactive wizard accepts Cyrillic name, rejects invalid port and accepts corrected port, validates LAN prefix and emits terminal colors')
    finally:
        if p.poll() is None: p.kill(); p.wait()
        os.close(primary)

    # Updating a legacy allowlist containing LAN only must not silently succeed.
    import json
    for entries,expected in [(['300:1111:2222:3333::/64'],False),
                             (['200:1111:2222:3333:4444:5555:6666:7777'],False),
                             (['200:1111:2222:3333:4444:5555:6666:7777','300:1111:2222:3333::/64'],True)]:
        (Path(d)/'access.json').write_text(json.dumps({'allowed_ips':entries}))
        r=subprocess.run(['bash',str(script)],stdin=subprocess.DEVNULL,capture_output=True,text=True)
        assert (r.returncode==0)==expected,(entries,r.stdout,r.stderr)
    print('PASS: noninteractive update rejects either missing field and preserves a complete saved pair')
