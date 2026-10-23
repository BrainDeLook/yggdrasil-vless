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
with tempfile.TemporaryDirectory(prefix='ygg-wizard-') as d:
    script=Path(d)/'wizard.sh'
    script.write_text('set -eu\nexec 3>&1\nBASE='+d+'\nNODE_NAME=""\nPORT=""\nREALITY_SERVER=""\nC_RESET="" C_CYAN="" C_YELLOW="" C_BOLD=""\nALLOW_IPS=()\nASSUME_YES=0\nINSTALLER_VERSION=test\ndie(){ echo "$*"; exit 1; }\n'+wizard+'\nconfigure_wizard\nprintf "RESULT:%s:%s\\n" "$NODE_NAME" "$PORT"\n')
    primary,secondary=pty.openpty()
    p=subprocess.Popen(['bash',str(script)],stdin=secondary,stdout=secondary,stderr=secondary)
    os.close(secondary)
    data=b''
    try:
        os.write(primary,'Моя нода NL\nневерный-порт\n2443\n200::/7\n200:1111:2222:3333:4444:5555:6666:7777 300:1111:2222:3333::/64\n'.encode())
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            if select.select([primary],[],[],.1)[0]:
                try: chunk=os.read(primary,65536)
                except OSError: break
                if not chunk: break
                data+=chunk
            elif p.poll() is not None: break
        p.wait(timeout=2)
        output=data.decode(errors='replace')
        assert p.returncode==0,output
        assert 'Название подключения' in output and 'Введите целое число' in output,output
        assert 'Ошибка списка доступа' in output and 'IPv6-PD' in output,output
        assert 'RESULT:Моя нода NL:2443' in output,output
        print('PASS: interactive wizard accepts Cyrillic name, rejects invalid port and accepts corrected port')
    finally:
        if p.poll() is None: p.kill(); p.wait()
        os.close(primary)
