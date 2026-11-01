"""Runs a bash command in a COLSxROWS pseudo-terminal, types each answer once the prompt it
answers has been drawn, waits for the command to exit, and writes everything it drew to stdout
(raw, escape codes included).
Usage: pty_drive.py COLS ROWS COMMAND [PROMPT|ANSWER...]   (in an answer, "\\n" is Enter)"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

cols, rows, command, answers = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], sys.argv[4:]
pid, fd = pty.fork()
if pid == 0:
    # Size the terminal before the command can ask for it.
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.environ["TERM"] = "xterm-256color"
    os.execvp("bash", ["bash", "-c", command])
out = b""
done = False


def read_until(want, limit=20.0):
    """Read until WANT has been drawn (None: until the command exits) or LIMIT seconds pass."""
    global out, done
    start = time.time()
    while not done and time.time() - start < limit:
        if want is not None and want in out:
            return
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                done = True
            out += chunk


for arg in answers:
    prompt, _, answer = arg.partition("|")
    read_until(prompt.encode())
    os.write(fd, answer.replace("\\n", "\n").encode())
read_until(None)
if not done:
    os.kill(pid, 9)
os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
