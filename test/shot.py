#!/usr/bin/env python3
"""shot.py <monitor-socket> <out.png> — screendump the VM's screen via the QEMU monitor."""
import os, socket, subprocess, sys, time

sock, out = sys.argv[1], sys.argv[2]
ppm = out[:-4] + ".ppm"
s = socket.socket(socket.AF_UNIX)
s.connect(sock)
time.sleep(0.2)
s.recv(65536)                                   # banner
s.sendall(f"screendump {ppm}\n".encode())
time.sleep(1.0)
s.close()
for _ in range(20):
    if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
        break
    time.sleep(0.25)
subprocess.run(["magick", ppm, out], check=True)
os.remove(ppm)
print(out)
