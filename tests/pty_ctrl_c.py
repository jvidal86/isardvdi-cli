"""Runs a bash command in a pseudo-terminal, presses Ctrl-C after 1.5 s and reports whether the
command stopped: prints "exited N s after Ctrl-C" or "still running 12 s after Ctrl-C"."""
import os
import pty
import sys
import time

pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", sys.argv[1]])
time.sleep(1.5)
start = time.time()
os.write(fd, b"\x03")
while not os.waitpid(pid, os.WNOHANG)[0]:
    if time.time() - start > 12:
        print("still running 12 s after Ctrl-C")
        os.kill(pid, 9)
        sys.exit(1)
    time.sleep(0.1)
print("exited %.1f s after Ctrl-C" % (time.time() - start))
