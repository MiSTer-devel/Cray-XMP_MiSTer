#!/usr/bin/env python3
"""Runs on the MiSTer (Python 3.9, standard library only).

Gives the test scripts what the CRAY X-MP core exposes to Linux:
  - the machine's memories, which are in DDR3 from physical 0x30000000 and
    visible through /dev/mem: central memory from word 0, the Buffer Memory
    of the I/O Subsystem from word 0o20000000, the boot file from word
    0o40000000.  Word n is 8 bytes at offset 8*n, most significant first.
  - the station's line on the HPS serial port /dev/ttyS1 (9600 8N1): what the
    station prints, as a terminal on that line would get it, and what is
    sent there is typed at the station.  The core sends only while a program
    here has the port open, and the station then prints at the line's speed.
  - a keyboard: keys typed here reach the core as a USB keyboard's would.
    F1 and F2 choose the console they go to.

Commands:
  peek WORD [COUNT]            print words in hex (WORD and COUNT accept 0o / 0x)
  poke WORD HEX [HEX ...]      write words
  fill WORD COUNT HEX          write one value to a range
  dump FILE WORD COUNT         save a range of memory to a file
  uart SECONDS [--send TEXT] [--until TEXT]
                               copy what the station's line carries to stdout
  keys TEXT [--gap SEC]        type on the keyboard
  play [--line] [--screen] [--gap SEC] STEP...
                               work the machine: type, wait, and with --line
                               watch the station's line
"""
import fcntl
import mmap
import os
import select
import struct
import sys
import termios
import time

BASE = 0x30000000
SPAN = 80 << 20           # central memory, Buffer Memory and the boot file
TTY = '/dev/ttyS1'


def mem():
    fd = os.open('/dev/mem', os.O_RDWR | os.O_SYNC)
    return mmap.mmap(fd, SPAN, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=BASE)


def num(s):
    return int(s, 0)


def cmd_peek(args):
    word = num(args[0])
    count = num(args[1]) if len(args) > 1 else 1
    m = mem()
    for i in range(count):
        print('%07o: %s' % (word + i, m[(word + i) * 8:(word + i) * 8 + 8].hex()))


def cmd_poke(args):
    word = num(args[0])
    m = mem()
    for i, h in enumerate(args[1:]):
        m[(word + i) * 8:(word + i) * 8 + 8] = int(h, 16).to_bytes(8, 'big')


def cmd_fill(args):
    word, count, val = num(args[0]), num(args[1]), int(args[2], 16).to_bytes(8, 'big')
    m = mem()
    m[word * 8:(word + count) * 8] = val * count


def cmd_dump(args):
    word, count = num(args[1]), num(args[2])
    m = mem()
    open(args[0], 'wb').write(m[word * 8:(word + count) * 8])


def open_tty():
    fd = os.open(TTY, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = 0                                             # iflag: raw
    a[1] = 0                                             # oflag
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL  # cflag
    a[3] = 0                                             # lflag
    a[4] = a[5] = termios.B9600
    a[6][termios.VMIN] = 0
    a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def cmd_uart(args):
    seconds = float(args[0])
    send = args[args.index('--send') + 1] if '--send' in args else None
    until = args[args.index('--until') + 1].encode() if '--until' in args else None
    fd = open_tty()
    got = b''
    end = time.time() + seconds
    sent = send is None
    out = sys.stdout.buffer
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            chunk = os.read(fd, 4096)
            got += chunk
            out.write(chunk)
            out.flush()
            if until and until in got:
                break
        elif not sent and time.time() > end - seconds + 0.5:
            os.write(fd, send.encode().decode('unicode_escape').encode('latin1'))
            sent = True
    os.close(fd)


UI_SET_EVBIT, UI_SET_KEYBIT, UI_DEV_CREATE, UI_DEV_DESTROY = 0x40045564, 0x40045565, 0x5501, 0x5502
EV_SYN, EV_KEY = 0, 1
KEY_CTRL, KEY_SHIFT = 29, 42
NAMED = {'enter': 28, 'esc': 1, 'tab': 15, 'backspace': 14, 'space': 57, 'up': 103, 'down': 108, 'left': 105,
         'right': 106, 'f1': 59, 'f2': 60, 'f3': 61, 'f4': 62, 'f5': 63, 'f6': 64, 'f7': 65, 'f8': 66, 'f9': 67,
         'f10': 68, 'f11': 87, 'f12': 88, 'delete': 111, 'insert': 110, 'home': 102, 'pagedown': 109, 'tab': 15}
PLAIN = dict(zip('1234567890-=', range(2, 14)))
PLAIN.update(zip('qwertyuiop[]', range(16, 28)))
PLAIN.update(zip('asdfghjkl;\'`', range(30, 42)))
PLAIN.update(zip('\\zxcvbnm,./', range(43, 54)))
PLAIN.update({' ': 57, '\r': 28, '\n': 28, '\t': 15, '\x08': 14})
SHIFTED = dict(zip('!@#$%^&*()_+', range(2, 14)))
SHIFTED.update(zip('{}', (26, 27)))
SHIFTED.update(zip(':"~', (39, 40, 41)))
SHIFTED.update(zip('|', (43,)))
SHIFTED.update(zip('<>?', (51, 52, 53)))


def key_steps(text):
    """(key code, shift, ctrl) for each key press named by `text`: characters,
    \\r \\n \\t \\xHH (control characters are typed with CTRL) and {name} for a
    special key such as {f12}, {enter}, {esc}, {up}, {down}; {s-name},
    {c-name} and {cs-name} hold SHIFT, CTRL or both with it."""
    text = text.encode().decode('unicode_escape')
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c == '{' and '}' in text[i:]:
            j = text.index('}', i)
            held, _, name = text[i + 1:j].lower().rpartition('-')
            if name in NAMED and held in ('', 's', 'c', 'cs'):
                out.append((NAMED[name], 's' in held, 'c' in held))
                i = j + 1
                continue
        i += 1
        if c in PLAIN: out.append((PLAIN[c], False, False))
        elif c in SHIFTED: out.append((SHIFTED[c], True, False))
        elif c.lower() in PLAIN and c.isupper(): out.append((PLAIN[c.lower()], True, False))
        elif 1 <= ord(c) <= 26: out.append((PLAIN[chr(ord(c) + 96)], False, True))
        else: sys.exit('no key for character %r' % c)
    return out


class Keyboard:
    """A virtual keyboard: what is typed here reaches the core as a USB keyboard's keys would."""

    def __init__(self, gap=0.06):
        self.gap = gap
        self.fd = os.open('/dev/uinput', os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        for code in range(1, 120):
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        # struct uinput_user_dev: name, bus/vendor/product/version, ff effects, 4 x 64 axis limits
        os.write(self.fd, struct.pack('80sHHHHi', b'Cray-XMP test keyboard', 3, 0x1209, 0xC1A1, 1, 0) + bytes(4 * 64 * 4))
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(5.0)                       # Main_MiSTer needs a while to open the new device

    def emit(self, code, value):
        os.write(self.fd, struct.pack('llHHi', 0, 0, EV_KEY, code, value) + struct.pack('llHHi', 0, 0, EV_SYN, 0, 0))
        time.sleep(self.gap / 2)

    def type(self, text):
        for code, shift, ctrl in key_steps(text):
            if ctrl: self.emit(KEY_CTRL, 1)
            if shift: self.emit(KEY_SHIFT, 1)
            self.emit(code, 1)
            self.emit(code, 0)
            if shift: self.emit(KEY_SHIFT, 0)
            if ctrl: self.emit(KEY_CTRL, 0)
            time.sleep(self.gap)

    def close(self):
        time.sleep(0.3)
        fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        os.close(self.fd)


def cmd_keys(args):
    """keys TEXT [--gap SEC]: type TEXT on a virtual keyboard."""
    keyboard = Keyboard(float(args[args.index('--gap') + 1]) if '--gap' in args else 0.06)
    keyboard.type(args[0])
    keyboard.close()


def squeeze(raw):
    """What a console was sent, without blanks, control characters and the
    escape sequences of an Ampex Dialogue 80: for finding a text whatever moved
    the cursor between its words."""
    out, n = [], 0
    while n < len(raw):
        c = raw[n]
        if c == 0x1B:
            n += 4 if raw[n + 1:n + 2] == b'=' else 3 if raw[n + 1:n + 2] == b'G' else 2
            continue
        if 0x20 < c < 0x7F:
            out.append(c)
        n += 1
    return bytes(out)


class Ampex:
    """The screen of an Ampex Dialogue 80, a character at a time: 24 lines of
    80 characters (the sequences are those of rtl/terminal/term_ampex.v)."""

    def __init__(self):
        self.lines = [bytearray(b' ' * 80) for _ in range(24)]
        self.line = self.column = 0
        self.escape = 0        # 1 after ESC, 2 the row follows, 3 the column, 4 one character to drop
        self.row = 0

    def feed(self):
        if self.line < 23:
            self.line += 1
        else:
            self.lines.pop(0)
            self.lines.append(bytearray(b' ' * 80))

    def put(self, c):
        c &= 0x7F
        if self.escape == 1:
            self.escape = 0
            if c == 0x3D:
                self.escape = 2
            elif c == 0x47:
                self.escape = 4
            elif c == 0x2A:
                self.lines = [bytearray(b' ' * 80) for _ in range(24)]
                self.line = self.column = 0
            elif c == 0x54:
                self.lines[self.line][self.column:] = b' ' * (80 - self.column)
            elif c == 0x52:
                self.lines.pop(self.line)
                self.lines.append(bytearray(b' ' * 80))
        elif self.escape == 2:
            self.row, self.escape = c, 3
        elif self.escape == 3:
            self.line = min(max(self.row - 0x20, 0), 23)
            self.column = min(max(c - 0x20, 0), 79)
            self.escape = 0
        elif self.escape == 4:
            self.escape = 0
        elif c == 0x1B:
            self.escape = 1
        elif c == 0x08:
            self.column = max(self.column - 1, 0)
        elif c == 0x0A:
            self.feed()
        elif c == 0x0C:
            self.column = min(self.column + 1, 79)
        elif c == 0x0D:
            self.column = 0
        elif 0x20 <= c < 0x7F:
            self.lines[self.line][self.column] = c
            if self.column < 79:
                self.column += 1
            else:
                self.column = 0
                self.feed()

    def text(self):
        text = [l.decode().rstrip() for l in self.lines]
        while text and not text[-1]:
            text.pop()
        return '\n'.join(text)


def render(raw):
    """The 24 lines a console shows after what it was sent."""
    screen = Ampex()
    for c in raw:
        screen.put(c)
    return screen.text()


def cmd_play(args):
    """play [--line] [--screen] [--gap SEC] STEP...

    Work the machine as somebody at its keyboard does.  A STEP is

      +N        wait N milliseconds
      ?TEXT     with --line: wait until the station's line has carried TEXT,
                whatever blanks and cursor movements lie between its
                characters; ?TEXT?N waits N seconds at most (default 60)
      >TEXT     with --line: send TEXT over the line, which types it at the
                station
      anything else is typed on the keyboard: \\r is RETURN, {f1} chooses the
      operator's console and {f2} the station.  Caps Lock is on in the core
      when it starts, so letters are typed small.

    The core has nothing that tells a program here what the operator's console
    shows: its steps are keys and waits.  With --line the station's line is
    open for the whole run, which makes the station print at the line's 9,600
    baud; what it carried is copied to the output, and --screen prints the
    station's 24 lines at the end.  Exit status 1 if a ?TEXT did not come."""
    line = '--line' in args
    show = '--screen' in args
    gap = float(args[args.index('--gap') + 1]) if '--gap' in args else 0.06
    steps, skip = [], False
    for a in args:
        if skip or a in ('--line', '--screen'):
            skip = False
        elif a == '--gap':
            skip = True
        else:
            steps.append(a)
    fd = open_tty() if line else None
    carried = bytearray()
    screen = Ampex()

    def listen(seconds):
        """Take what the line brings for so long."""
        end = time.time() + seconds
        while True:
            left = end - time.time()
            if fd is None:
                time.sleep(max(left, 0))
                return
            r, _, _ = select.select([fd], [], [], max(min(left, 0.05), 0))
            if r:
                chunk = os.read(fd, 4096)
                carried.extend(chunk)
                for b in chunk:
                    screen.put(b)
                sys.stdout.write(''.join(chr(b) for b in chunk if b == 0x0A or 0x20 <= b < 0x7F))
                sys.stdout.flush()
            if left <= 0:
                return

    keyboard = Keyboard(gap)
    missed = None
    for step in steps:
        if step[:1] == '+' and step[1:].isdigit():
            listen(int(step[1:]) / 1000)
        elif step[:1] == '?' and line:
            want, _, limit = step[1:].partition('?')
            want, since, end = squeeze(want.encode()), len(carried), time.time() + float(limit or 60)
            while want not in squeeze(bytes(carried[since:])) and time.time() < end:
                listen(0.1)
            if want not in squeeze(bytes(carried[since:])):
                missed = step[1:]
                break
        elif step[:1] == '>' and line:
            for b in step[1:].replace('\\r', '\r').encode():
                os.write(fd, bytes([b]))
                listen(0.006)                 # the kernel takes some 300 characters a second
        else:
            keyboard.type(step)
            listen(0)
    listen(0.3)
    keyboard.close()
    if fd is not None:
        os.close(fd)
    if show:
        print('\n---- station\n%s\n----' % screen.text())
    if line:
        print('\n%d characters on the station\'s line' % len(carried))
    if missed:
        print('the station did NOT print `%s`' % missed)
        sys.exit(1)


COMMANDS = {'keys': cmd_keys, 'peek': cmd_peek, 'poke': cmd_poke, 'fill': cmd_fill, 'dump': cmd_dump, 'uart': cmd_uart,
            'play': cmd_play}

if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](sys.argv[2:])
