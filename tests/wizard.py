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
                   ('Разрешённые IP / подсети','200::/7\n'),
                   ('Ошибка списка доступа','200:1111:2222:3333:4444:5555:6666:7777 300:1111:2222:3333::/64\n')]
        next_response=0
        deadline=time.monotonic()+15
        while time.monotonic()<deadline:
            if select.select([primary],[],[],.1)[0]:
                try: chunk=os.read(primary,65536)
                except OSError: break
                if not chunk: break
                data+=chunk
                if next_response<len(responses):
                    trigger,response=responses[next_response]
                    if trigger.encode() in data:
                        os.write(primary,response.encode())
                        next_response+=1
            elif p.poll() is not None: break
        p.wait(timeout=2)
        output=data.decode(errors='replace')
        assert p.returncode==0,output
        assert '\x1b[36m' in output and '\x1b[33m' in output and '\x1b[0m' in output,output
        assert 'Название подключения' in output and 'Введите целое число' in output,output
        assert 'Ошибка списка доступа' in output and 'IPv6-PD' in output,output
        assert 'RESULT:Моя нода NL:2443' in output,output
        assert next_response==len(responses),output
        print('PASS: queued blank lines do not skip name; interactive wizard accepts Cyrillic name, rejects invalid port and accepts corrected port, validates LAN prefix and emits terminal colors')
    finally:
        if p.poll() is None: p.kill(); p.wait()
        os.close(primary)
