import struct, subprocess, sys
html = b'<!doctype html><html><body style="font-family:Helvetica"><h1 style="color:#0a7">Hello WebKit</h1><p>Subprocess pipeline ok.</p></body></html>'
cfg = b'{"paper_w_pt":595,"paper_h_pt":842,"margin_top_pt":36,"margin_right_pt":36,"margin_bottom_pt":36,"margin_left_pt":36}'
payload = struct.pack('>I', len(cfg)) + cfg + struct.pack('>I', len(html)) + html
p = subprocess.Popen(['./out/wkhtmltox-helper'],
                     stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE,
                     stderr=sys.stderr,
                     bufsize=0)
p.stdin.write(payload); p.stdin.close()
out = p.stdout.read()
rc = p.wait()
print('exit', rc, 'stdout_len', len(out))
if len(out) >= 8:
    status, ln = struct.unpack('>II', out[:8])
    print('status=', status, 'len=', ln)
    if status == 1:
        open('/tmp/helper-smoke.pdf', 'wb').write(out[8:8+ln])
        print('wrote /tmp/helper-smoke.pdf', ln, 'bytes')
    else:
        print('error msg:', out[8:8+ln].decode(errors='replace'))
