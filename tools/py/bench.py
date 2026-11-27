#!/usr/bin/env python3
"""The benchmark: the kernels of tests/bench/xbench.cal, timed in clock periods.

  bench.py sim [--mem PROFILE]... [--rep N] [--seed N] [--only NAME,...] [--sim VCRAY_CPU]
               [--save FILE] [--against FILE]
                           run it in the CPU simulation (make tools, make -C sim cpu)
  bench.py job [-o FILE] [--rep N] [--trials N] [--only NAME,...]
                           write it as a job for COS
  bench.py mister [--rep N] [--trials N] [--only NAME,...] [--running] [--wait SEC]
               [--save FILE] [--against FILE]
                           run that job on a MiSTer and read its times
  bench.py read PRINTOUT [--last] [--save FILE] [--against FILE]
                           the times of a job somebody ran, from what it printed
  bench.py model [--only NAME,...]
                           run the job under COS on the system model, as a check
  bench.py compare OLD NEW [LABEL]
                           two saved runs side by side
  bench.py list            the kernels

A time is the clock periods a kernel takes for one unit of its work (an
element of a loop, a call, a number sorted), so a smaller number is the
faster machine.  It is counted by the machine's own real-time clock, around
the kernel and nothing else.

sim runs the program on sim/build/cpu/Vcray_cpu.  PROFILE is what follows
that simulator's --mem (default: mister, the DE10-Nano's DDR3 as measured);
with several, a column each.  The reference model runs the same program
first and every kernel's sum must be the model's, so a change that makes a
kernel compute something else is reported and not timed.  --only names the
kernels to run, the others are left out of the program.

mister puts the job on a copy of the expander disk on the MiSTer
(bench_disk.img beside exp_disk.img), starts the core with it, dead starts
COS as the README's steps do, submits the job and reads what it printed in
the printer's file.  It types on a keyboard it gives the MiSTer, at times
that leave room for each answer, since nothing tells it what the consoles
show.  With --running the core is taken as it is, with COS started and the
job on the disk it runs from.  A kernel runs --trials times (5) and the fastest is
its time: COS's interrupts are in the others, and so is whatever the
MiSTer's Linux did in memory meanwhile (the machine's memory is a region
Linux has no part of, but the DDR3 and its controller are the same), which
is why nothing is asked of the MiSTer while the job runs.  The sums are
checked as in the simulation.  It needs what hil.py needs, and takes the
core and the images that script's MISTER_RBF and MISTER_SET name.

model takes the package in releases and runs the job on cray-xmp-sys: COS's
own assembler has to take the kernels and their sums have to be right.  The
times it prints are not shown: an instruction is four clock periods there.

--save writes a run to a file, --against shows a run beside a saved one
with the change in percent, and compare does that for two saved files.  A
file holds a column for each name a run has (a memory profile, or hardware):
saving to a file that is there replaces the columns of the same name and
keeps the others.  The mean at the foot is the geometric mean of the kernels
both runs have.

A kernel is added in tests/bench/xbench.cal, whose first lines have the rules.
"""
import json
import math
import os
import re
import subprocess
import sys
import time
from typing import NoReturn

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
SOURCE = os.path.join(ROOT, 'tests/bench/xbench.cal')
ASM = os.path.join(ROOT, 'tools/target/release/cray-xmp')
MODEL = os.path.join(ROOT, 'tools/target/release/cray-xmp-run')
SIM = os.path.join(ROOT, 'sim/build/cpu/Vcray_cpu')
OUT = os.path.join(ROOT, 'build/bench')
BLOCK = 32                      # words of an instruction buffer
JOB = 'JXBENCH'                 # the job's file in STATION on the expander disk
CLOCK_NS = 9.5
LINE = re.compile(r'XBENCH (\d\d) (\S+)\s+([0-7]{22})\s+([0-7]{22})')
HEAD = re.compile(r'XBENCH RUN\s+([0-7]{22})\s+([0-7]{22})')
STEP = re.compile(r'\s*\d\d:\d\d:\d\d\.\d+\s+(\d+\.\d+)\s+CSP\s+(CAL,I=SRC|LDR,AB|\$ABD\.)')
REP, TRIALS = 300, 5            # of a job, unless given
# What the operator types to get from a core just loaded to a COS that takes jobs (the README's
# steps), on the keyboard, with waits between.  Nothing tells a script what the operator's
# console shows, so the waits are times that leave room: the kernel asks for the date after
# 13 s, or 27 s with the menu's "Device times: Real".  Letters are typed small: Caps Lock is
# on in the core.  {f1} is the operator's console, {f2} the station.
STARTUP = ['+40000', '{f1}10/05/89\\r', '+2000', '01:02:03\\r', '+3000', 'start cos_117 deadstart\\r', '+25000',
           'station\\r', '+3000', '{f2}logon\\r', '+4000', 'stmsg\\r', '+6000', 'reply,0,go\\r', '+35000',
           'stmsg,i\\r', '+8000', 'class,all,on\\r', '+2000', 'limit,5\\r', '+2000']
SUBMIT = ['{f2}submit,jxbench\\r', '+1000']
ROOM = 200000                   # bytes of the printer's file a job's printout is looked for in


def die(text) -> NoReturn:
    sys.exit('bench: ' + text)


# ---------------------------------------------------------------- the source

def load_source(only=None):
    """The kernel file in its parts: init, kernels, extra code, data."""
    src = {'init': [], 'kernels': [], 'extra': [], 'data': []}
    part = None
    for number, line in enumerate(open(SOURCE).read().splitlines(), 1):
        mark = re.match(r'\*([IKTEXD])(\s|$)', line)
        if mark:
            m = mark.group(1)
            if m == 'K':
                f = line.split(None, 4)
                if len(f) < 5 or not f[2].isdigit():
                    die('%s:%d: a kernel is "*K name units group text"' % (SOURCE, number))
                src['kernels'].append({'name': f[1], 'units': int(f[2]), 'group': f[3], 'text': f[4],
                                       'setup': [], 'timed': [], 'sum': []})
                part = src['kernels'][-1]['setup']
            elif m in 'TE':
                if not src['kernels']:
                    die('%s:%d: *%s outside a kernel' % (SOURCE, number, m))
                part = src['kernels'][-1]['timed' if m == 'T' else 'sum']
            else:
                part = src[{'I': 'init', 'X': 'extra', 'D': 'data'}[m]]
        elif part is not None and not line.startswith('*') and line.strip():
            part.append(line)
    names = [k['name'] for k in src['kernels']]
    for k in src['kernels']:
        if len(k['name']) > 8 or names.count(k['name']) > 1 or not k['timed']:
            die('kernel %s: a name of up to 8 characters, used once, and code behind *T' % k['name'])
    if only:
        missing = [n for n in only if n not in names]
        if missing:
            die('no kernel %s (bench.py list)' % ', '.join(missing))
        src['kernels'] = [k for k in src['kernels'] if k['name'] in only]
    return src


def ins(result, operand='', label=''):
    return ('%-8s %-9s %s' % (label, result, operand)).rstrip()


def words(text):
    """A text as CON lines, eight characters a word."""
    return [ins('CON', "O'%022o" % int.from_bytes(text[i:i + 8].encode('ascii'), 'big'))
            for i in range(0, len(text), 8)]


def program(src, cos, rep, trials, pads):
    """The program: for the CPU simulation, or for COS (cos)."""
    kernels = src['kernels']
    nk = len(kernels)
    t = ['* Written by tools/py/bench.py from tests/bench/xbench.cal.']
    if cos:
        t += [ins('IDENT', 'XBENCH'), ins('ENTRY', 'XBENCH'), ins('START', 'XBENCH')]
    else:
        t += [ins('INCLUDE', '"rt_direct.cal"')]
    t += [ins('=', "D'4096", 'N')]
    if not cos:
        t += [ins('TBEGIN')]
    # from here to XDONE the two programs are the same lines, so that every
    # instruction is in the same place of its instruction buffer in both
    t += [ins('A0', '0', 'XBENCH')] + src['init'] + [ins('R', 'XHELLO'), ins('A0', '0', 'XTL')]
    for i, k in enumerate(kernels):
        t += ['* ' + k['name']] + k['setup']
        t += [ins('J', 'XK%02d' % i), ins('BSS', "D'%d" % pads[i]),
              ins('S7', 'RT', 'XK%02d' % i), ins('XT0,0', 'S7')]
        t += k['timed']
        t += [ins('CMR', '', 'XE%02d' % i), ins('S7', 'RT'), ins('S6', 'XT0,0'), ins('S7', 'S7-S6'),
              ins('A7', 'XTRI,0'), ins("XRES+D'%d,A7" % i, 'S7')]
        t += k['sum']
        t += [ins('A1', 'XTRI,0'), ins("XSUM+D'%d,A1" % i, 'S1'), ins('A2', "D'%d" % i), ins('R', 'XREPORT')]
    t += [ins('A1', 'XTRI,0'), ins('A2', "D'%d" % nk), ins('A1', 'A1+A2'), ins('XTRI,0', 'A1'),
          ins('A2', 'XTEND,0'), ins('A0', 'A2-A1'), ins('JAN', 'XTL'), ins('J', 'XDONE')]
    t += src['extra']
    if cos:
        # the end of the job step, and the lines for the job's log: first the
        # repetitions and how many times there will be, then for every time
        # the kernel's name, its clock periods and its sum; numbers in octal
        t += [ins('S0', '0', 'XDONE'), ins('EX'),
              ins('S6', 'XREP,0', 'XHELLO'), ins('S7', 'XTEND,0'), ins('A4', 'XHEAD'), ins('J', 'XSAY'),
              ins('A3', 'XTRI,0', 'XREPORT'), ins('A3', 'A3+A2'), ins('S6', 'XRES,A3'), ins('S7', 'XSUM,A3'),
              ins('A4', 'A2+A2'), ins('A4', 'A4+A2'), ins('A3', 'XNAME'), ins('A4', 'A4+A3'),
              # the three words at (A4), (S6) and (S7) as a line of the log
              ins('A3', 'B00', 'XSAY'), ins('B77', 'A3')]
        for n in range(3):
            t += [ins('S1', "D'%d,A4" % n), ins("XMSG+D'%d,0" % n, 'S1')]
        t += [ins('S1', 'S6'), ins('A2', "XMSG+D'3"), ins('R', 'XOCT'),
              ins('S1', 'S7'), ins('A2', "XMSG+D'6"), ins('R', 'XOCT'),
              ins('S0', '4'), ins('S1', 'XMSG'), ins('S2', "O'17"), ins('EX'), ins('J', 'B77'),
              # (S1) as two blanks and 22 octal digits in the three words from (A2)
              ins('S2', 'S1', 'XOCT'), ins('S3', "O'20040"), ins('A4', '2'), ins('A5', "D'22"),
              ins('A3', '1'), ins('A6', "D'8"),
              ins('S4', '0', 'XOC1'), ins('S4', 'S4,S2<A3'), ins('S2', 'S2<A3'), ins('A3', '3'),
              ins('S5', "O'60"), ins('S4', 'S4!S5'), ins('S3', "S3<D'8"), ins('S3', 'S3!S4'),
              ins('A4', 'A4+1'), ins('A0', 'A4-A6'), ins('JAN', 'XOC2'),
              ins('0,A2', 'S3'), ins('A2', 'A2+1'), ins('A4', '0'), ins('S3', '0'),
              ins('A5', 'A5-1', 'XOC2'), ins('A0', 'A5'), ins('JAN', 'XOC1'), ins('J', 'B00')]
    else:
        t += [ins('TPASS', '', 'XDONE'), ins('TEND'), ins('J', 'B00', 'XREPORT'), ins('J', 'B00', 'XHELLO')]
    t += [ins('CON', "D'%d" % rep, 'XREP'), ins('CON', "D'%d" % (trials * nk), 'XTEND'),
          ins('CON', '0', 'XTRI'), ins('CON', '0', 'XT0'),
          ins('BSSZ', "D'%d" % (trials * nk), 'XRES'), ins('BSSZ', "D'%d" % (trials * nk), 'XSUM')]
    for i, k in enumerate(kernels):
        lines = words('XBENCH %02d %-8s      ' % (i, k['name']))
        t += [('XNAME' if i == 0 else '').ljust(9) + lines[0][9:]] + lines[1:]
    head = words('XBENCH RUN              ')
    t += ['XHEAD'.ljust(9) + head[0][9:]] + head[1:]
    t += [ins('BSSZ', "D'10", 'XMSG')] + src['data'] + [ins('END')]
    return '\n'.join(t) + '\n'


def assemble(text, name):
    """Assemble a program for the simulation; its image and its symbols (in parcels)."""
    os.makedirs(OUT, exist_ok=True)
    base = os.path.join(OUT, name)
    open(base + '.cal', 'w').write(text)
    if not os.path.exists(ASM):
        die('no %s; run `make tools`' % ASM)
    r = subprocess.run([ASM, 'asm', base + '.cal', '-o', base + '.img', '-l', base + '.lst',
                        '-I', os.path.join(ROOT, 'tests/rt')], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        die('the kernels do not assemble:\n' + r.stderr.decode()[:2000])
    symbols = {}
    for line in open(base + '.lst'):
        m = re.match(r'(\S+)\s+([0-7]+) ([PWV])$', line.rstrip())
        if m:
            symbols[m.group(1)] = int(m.group(2), 8) * (4 if m.group(3) == 'W' else 1)
    return base + '.img', symbols


def build(src, rep, trials):
    """The pads that put each kernel at the start of an instruction buffer, and
    the program for the simulation with them."""
    nk = len(src['kernels'])
    pads = [1] * nk
    _, symbols = assemble(program(src, False, rep, trials, pads), 'xbench')
    moved = 0
    for i in range(nk):
        at = symbols['XK%02d' % i] // 4 + moved
        pads[i] = 1 + -at % BLOCK
        moved += pads[i] - 1
    image, symbols = assemble(program(src, False, rep, trials, pads), 'xbench')
    for i, k in enumerate(src['kernels']):
        start, end = symbols['XK%02d' % i], symbols['XE%02d' % i]
        if start % (4 * BLOCK):
            die('kernel %s is not at the start of an instruction buffer' % k['name'])
        if end - start > 4 * BLOCK:
            die('kernel %s: %d parcels from *T to *E, more than an instruction buffer holds (%d)'
                % (k['name'], end - start, 4 * BLOCK))
    return pads, image, symbols


# ------------------------------------------------------------------ the runs

def model_sums(image, symbols, nk):
    """Every kernel's sum on the reference model."""
    state = image[:-4] + '.model'
    r = subprocess.run([MODEL, image, '--state', state, '--quiet', '--max', '4000000000'],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        die('the reference model does not run the kernels: exit %d\n%s' % (r.returncode, r.stderr.decode()[-600:]))
    first = symbols['XSUM'] // 4
    sums = {}
    for line in open(state):
        f = line.split()
        if f[0] == 'mem' and first <= int(f[1], 8) < first + nk:
            sums[int(f[1], 8) - first] = None if f[2] == 'undef' else int(f[2], 16)
    return [sums.get(i) for i in range(nk)]


def simulate(sim, image, symbols, nk, profile, seed, rep):
    """Clock periods and sums of one run of the CPU simulation."""
    r = subprocess.run([sim, '--image', image, '--mem', profile, '--seed', str(seed), '--quiet',
                        '--cycles', str(400000000 * rep), '--dump', '%o:%o' % (symbols['XRES'] // 4, 2 * nk)],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if r.returncode != 0:
        die('the simulation with --mem %s failed: %s' % (profile, r.stderr.decode()[-400:]))
    got = [int(line.split(':')[1], 8) for line in r.stdout.decode().splitlines() if re.match(r'[0-7]+: [0-7]+$', line)]
    if len(got) != 2 * nk:
        die('the simulation printed %d words where %d were asked for' % (len(got), 2 * nk))
    return got[:nk], got[nk:]


def column(label, src, clocks, rep, **more):
    """A run as it is saved: for every kernel the clock periods of a unit."""
    col = {'label': label, 'rep': rep, 'kernels': {}}
    col.update(stamp())
    col.update(more)
    for k, c in zip(src['kernels'], clocks):
        col['kernels'][k['name']] = {'cp': c / (rep * k['units']), 'clocks': c, 'units': k['units'], 'group': k['group']}
    return col


def stamp():
    """Which sources a run is of: the commit, and whether RTL or the simulation's
    harness differ from it."""
    def git(*a):
        r = subprocess.run(['git', '-C', ROOT] + list(a), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return r.stdout.decode().strip()
    return {'commit': git('rev-parse', '--short', 'HEAD'),
            'changed': bool(git('status', '--porcelain', '--untracked-files=no', '--', 'rtl', 'sim', 'Cray-XMP.sv')),
            'date': time.strftime('%Y-%m-%d %H:%M')}


def check_sums(src, sums, want, where):
    bad = [k['name'] for k, s, w in zip(src['kernels'], sums, want) if s != w]
    undefined = [k['name'] for k, w in zip(src['kernels'], want) if w is None]
    if undefined:
        die('the reference model has no sum for %s: the kernel reads something it never set' % ', '.join(undefined))
    if bad:
        die('%s: the sum of %s is not the reference model\'s; the times of a kernel that computes '
            'something else mean nothing' % (where, ', '.join(bad)))


# ---------------------------------------------------------------- the tables

def geomean(values):
    return math.exp(sum(math.log(v) for v in values) / len(values)) if values else float('nan')


def show(src, columns, old=None):
    """The columns side by side; with old, each beside the saved column of the
    same label and the change in percent.  The two steps of the job that COS
    timed come behind the mean, which is of the kernels."""
    old = {c['label']: c for c in (old or {}).get('columns', [])}
    head = '%-9s%-7s' % ('kernel', 'group')
    for c in columns:
        head += '%10s' % c['label'][:9]
        if c['label'] in old:
            head += '%10s%8s' % ('was', 'change')
    print(head)

    def number(v):
        return '%.2f' % v if v < 100000 else '%.0f' % v

    def row(name):
        group = next(c['kernels'][name]['group'] for c in columns if name in c['kernels'])
        text = '%-9s%-7s' % (name, group)
        for c in columns:
            new = c['kernels'].get(name)
            text += '%10s' % (number(new['cp']) if new else '-')
            if c['label'] in old:
                was = old[c['label']]['kernels'].get(name)
                text += '%10s' % (number(was['cp']) if was else '-')
                text += '%8s' % ('%+.1f%%' % (100 * (new['cp'] / was['cp'] - 1)) if new and was else '-')
        print(text)

    have = {n: k['group'] for c in columns for n, k in c['kernels'].items()}
    order = [k['name'] for k in src['kernels']] if src else []
    order += sorted(n for n in have if n not in order)
    for name in order:
        if name in have and have[name] != 'cos':
            row(name)
    foot = '%-16s' % 'geometric mean'
    for c in columns:
        both = [n for n, k in c['kernels'].items() if k['group'] != 'cos'
                and (c['label'] not in old or n in old[c['label']]['kernels'])]
        mean = geomean([c['kernels'][n]['cp'] for n in both])
        foot += '%10.2f' % mean
        if c['label'] in old:
            was = geomean([old[c['label']]['kernels'][n]['cp'] for n in both])
            foot += '%10.2f%8s' % (was, '%+.1f%%' % (100 * (mean / was - 1)))
    print(foot)
    for name in order:
        if name in have and have[name] == 'cos':
            row(name)
    for c in columns:
        if c['label'] in old and old[c['label']].get('rep') != c.get('rep'):
            print('(%s: %s repetitions now, %s then)' % (c['label'], c.get('rep'), old[c['label']].get('rep')))


def load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError) as e:
        die('%s: %s' % (path, e))


def source_of(col):
    """Which machine a column is of: the commit of a simulation, the core file of a MiSTer."""
    what = col.get('core') or (col['commit'] + (' with changes' if col.get('changed') else '') if col.get('commit')
                               else 'a printout')
    return '%s, %s' % (what, col.get('date', '?'))


def finish(src, columns, opts):
    old = load(opts['against']) if opts.get('against') else None
    show(src, columns, old)
    if old:
        for c in old['columns']:
            if any(c['label'] == new['label'] for new in columns):
                print('%s in %s: %s' % (c['label'], opts['against'], source_of(c)))
    if opts.get('save'):
        # a file is a column a label: these take the place of their namesakes
        kept = load(opts['save'])['columns'] if os.path.exists(opts['save']) else []
        kept = [c for c in kept if not any(c['label'] == new['label'] for new in columns)]
        json.dump({'columns': kept + columns}, open(opts['save'], 'w'), indent=1)
        print('saved to %s%s' % (opts['save'], ' beside ' + ', '.join(c['label'] for c in kept) if kept else ''))


# -------------------------------------------------------------- the commands

def options(args, flags=()):
    """--name value pairs (--mem may come several times), and the flags given."""
    opts: dict = {'mem': []}
    rest = []
    while args:
        a = args.pop(0)
        if a in flags:
            opts[a[2:]] = True
        elif a == '-o' and args:
            opts['o'] = args.pop(0)
        elif a.startswith('--') and args:
            if a == '--mem':
                opts['mem'].append(args.pop(0))
            else:
                opts[a[2:]] = args.pop(0)
        else:
            rest.append(a)
    for name in ('rep', 'trials', 'seed', 'wait'):
        if name in opts:
            if not str(opts[name]).isdigit() or int(opts[name]) < 1:
                die('--%s takes a number' % name)
            opts[name] = int(opts[name])
    if 'only' in opts:
        opts['only'] = opts['only'].upper().split(',')
    return opts, rest


def cmd_sim(args):
    opts, _ = options(args)
    src = load_source(opts.get('only'))
    rep = opts.get('rep', 1)
    sim = opts.get('sim', SIM)
    if not os.path.exists(sim):
        die('no %s; run `make -C sim cpu`' % sim)
    _, image, symbols = build(src, rep, 1)
    nk = len(src['kernels'])
    want = model_sums(image, symbols, nk)
    columns = []
    for profile in opts['mem'] or ['mister']:
        clocks, sums = simulate(sim, image, symbols, nk, profile, opts.get('seed', 1), rep)
        check_sums(src, sums, want, '--mem ' + profile)
        columns.append(column(profile, src, clocks, rep, where='sim', seed=opts.get('seed', 1)))
    finish(src, columns, opts)


def cmd_list(args):
    for k in load_source()['kernels']:
        print('%-9s%-7s%6d  %s' % (k['name'], k['group'], k['units'], k['text']))


def cmd_compare(args):
    if len(args) < 2:
        die('compare OLD NEW [LABEL]')
    old, new = load(args[0]), load(args[1])
    columns = [c for c in new['columns'] if len(args) < 3 or c['label'] == args[2]]
    labels = {c['label'] for c in old['columns']}
    if not any(c['label'] in labels for c in columns):
        die('the two files have no run in common: %s has %s, %s has %s'
            % (args[0], ', '.join(sorted(labels)), args[1], ', '.join(c['label'] for c in new['columns'])))
    show(load_source(), columns, old)
    for c in columns:
        was = [o for o in old['columns'] if o['label'] == c['label']]
        if was:
            print('%s: %s (%s), was %s (%s)' % (c['label'], source_of(c), args[1], source_of(was[0]), args[0]))


def deck(src, rep, trials, pads):
    """The job: its statements, and behind them the program for COS's assembler."""
    statements = ['JOB,JN=XBENCH,T=1800.', 'ACCOUNT,AC=CRAY,US=SYSTEM.', 'COPYF,O=SRC.', 'REWIND,DN=SRC.',
                  'MEMORY,FL,USER.', 'CAL,I=SRC,L=0.', 'LDR,AB,DN=$BLD.', '$ABD.', '/EOF']
    return '\n'.join(statements) + '\n' + program(src, True, rep, trials, pads)


def prepare(opts):
    """What every way of running the job needs: the kernels, the sums the
    reference model gives them, and the job."""
    src = load_source(opts.get('only'))
    pads, image, symbols = build(src, 1, 1)
    want = model_sums(image, symbols, len(src['kernels']))
    check_sums(src, want, want, 'the reference model')
    rep, trials = opts.get('rep', REP), opts.get('trials', TRIALS)
    path = os.path.join(OUT, JOB + '.txt')
    text = deck(src, rep, trials, pads)
    open(path, 'w').write(text)
    return src, want, path, text.count('\n') - 9


def printed(src, want, text, label, last=True, lines=0):
    """The run in what a job printed: for every kernel the fastest of its
    times.  With last the job printed last, otherwise the only one.  lines
    is the lines of the program the job assembled."""
    heads = list(HEAD.finditer(text))
    if not heads:
        failed = [line.strip() for line in text.splitlines() if ' ABORT' in line or ' CA0' in line or 'ERROR' in line]
        die('nothing of the benchmark is in the printout' + (':\n' + '\n'.join(failed[-8:]) if failed else ''))
    if len(heads) > 1 and not last:
        die('the printout has %d runs of the benchmark; --last takes the last' % len(heads))
    rep, total = int(heads[-1].group(1), 8), int(heads[-1].group(2), 8)
    times, sums, names = {}, {}, {}
    for m in LINE.finditer(text, heads[-1].end()):
        i = int(m.group(1))
        names[i] = m.group(2)
        times.setdefault(i, []).append(int(m.group(3), 8))
        sums.setdefault(i, set()).add(int(m.group(4), 8))
    if sum(len(v) for v in times.values()) != total:
        die('the job printed %d of its %d times: it did not run to its end'
            % (sum(len(v) for v in times.values()), total))
    known = {k['name']: (k, w) for k, w in zip(src['kernels'], want)}
    strangers = sorted(n for n in names.values() if n not in known)
    if strangers:
        die('the job has kernels this source does not have (%s): it was made from another xbench.cal'
            % ', '.join(strangers))
    bad = sorted(names[i] for i in names if sums[i] != {known[names[i]][1]})
    if bad:
        die('the sum of %s is not the reference model\'s; the times of a kernel that computes '
            'something else mean nothing' % ', '.join(bad))
    col = {'label': label, 'rep': rep, 'trials': total // len(names), 'where': 'COS', 'kernels': {},
           'date': time.strftime('%Y-%m-%d %H:%M')}
    for i in sorted(names):
        k = known[names[i]][0]
        best = min(times[i])
        col['kernels'][k['name']] = {'cp': best / (rep * k['units']), 'clocks': best, 'units': k['units'],
                                     'group': k['group'], 'spread': max(times[i]) / best - 1}
    # The two steps that made the program, by the CPU time COS charged them:
    # its log has the job's CPU time in front of every statement.  COS counts
    # the time in clock periods of 9.5 ns.
    charged = {}
    for line in text[:heads[-1].start()].splitlines():
        m = STEP.match(line)
        if m:
            charged[m.group(2).split(',')[0].rstrip('.')] = float(m.group(1))
    for name, behind in (('CAL', 'LDR'), ('LDR', '$ABD')):
        if name in charged and behind in charged and lines:
            clocks = round((charged[behind] - charged[name]) / (CLOCK_NS * 1e-9))
            col['kernels'][name] = {'cp': clocks / lines, 'clocks': clocks, 'units': lines, 'group': 'cos'}
    return col


def spread(col):
    timed = {n: k for n, k in col['kernels'].items() if 'spread' in k}
    worst = max(timed.items(), key=lambda kv: kv[1]['spread'])
    seconds = sum(k['clocks'] for k in timed.values()) * CLOCK_NS * 1e-9
    print('%d repetitions, the fastest of %d times; a pass through the kernels takes %.1f s; the slowest '
          'time of a kernel is at most %.2f%% above its fastest (%s)'
          % (col['rep'], col['trials'], seconds, 100 * worst[1]['spread'], worst[0]))


def cmd_job(args):
    opts, _ = options(args)
    src, _, path, _ = prepare(opts)
    if 'o' in opts:
        open(opts['o'], 'w').write(open(path).read())
        path = opts['o']
    print('%s: %d kernels, %d repetitions, %d times each' % (path, len(src['kernels']), opts.get('rep', REP),
                                                           opts.get('trials', TRIALS)))
    print('python3 tools/py/expdisk.py puttext exp_disk.img STATION/%s %s' % (JOB, path))
    print('then SUBMIT,%s at the station, and bench.py read on what it printed' % JOB)


def cmd_read(args):
    opts, rest = options(args, flags=('--last',))
    if len(rest) != 1:
        die('read PRINTOUT [--last] [--save FILE] [--against FILE]')
    src, want, _, lines = prepare({})
    col = printed(src, want, open(rest[0], errors='replace').read(), 'hardware', opts.get('last', False), lines)
    spread(col)
    finish(src, [col], opts)


def cmd_model(args):
    """The job under COS on the system model: COS's own assembler takes the
    kernels, and they compute what they should.  An instruction is four
    clock periods there, so the times say nothing."""
    import shutil
    import zipfile
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import mkcos
    opts, _ = options(args)
    opts.setdefault('rep', 1)
    opts.setdefault('trials', 1)
    src, want, path, lines = prepare(opts)
    work = os.path.join(OUT, 'cos')
    package = os.path.join(ROOT, 'releases', 'Cray-XMP_COS-1.17.zip')
    os.makedirs(os.path.join(work, 'target', 'cos_117'), exist_ok=True)
    with zipfile.ZipFile(package) as z:
        for name in ('drives.img', 'exp_disk.img'):
            # (a copy older than the package is of an earlier package)
            copy = os.path.join(work, name)
            if not os.path.exists(copy) or os.path.getmtime(copy) < os.path.getmtime(package):
                with z.open('games/%s/%s' % (mkcos.CORE, name)) as f, open(copy, 'wb') as g:
                    shutil.copyfileobj(f, g)
    shutil.copyfile(os.path.join(mkcos.SYSTEM, 'boot_tape.tap'), os.path.join(work, 'boot_tape.tap'))
    shutil.copyfile(os.path.join(mkcos.SYSTEM, 'iop_kern.bin'), os.path.join(work, 'target', 'cos_117', 'iop_kern.bin'))
    disk = bytearray(open(os.path.join(work, 'exp_disk.img'), 'rb').read())
    mkcos.replace(disk, 'STATION/' + JOB, mkcos.job(open(path).read().splitlines()))
    script = (mkcos.START % ('12:00:00', 'DEADSTART') + mkcos.JOBS
              + 'type station SUBMIT,%s\nwait printer JOB,JN=XBENCH\nwait printer END OF JOB\nrun 3000\nprinter\n' % JOB)
    shutil.rmtree(os.path.join(work, 'run'), ignore_errors=True)
    text = mkcos.model(work, 'run', disk, os.path.join(work, 'drives.img'), script, None, opts.get('wait', 3600))
    open(os.path.join(OUT, 'model.txt'), 'w').write(text)
    col = printed(src, want, text, 'model', True, lines)
    print('COS assembled the kernels and ran them on the system model; every sum is right '
          '(the printout is in %s)' % os.path.join(OUT, 'model.txt'))
    return col


def cmd_mister(args):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import hil
    opts, _ = options(args, flags=('--running',))
    src, want, path, lines = prepare(opts)
    games = hil.GAMES

    def paper(behind, seconds):
        """What the printer's file holds behind its first `behind` bytes, once
        END OF JOB is there or the seconds are over, without the empty lines at
        its end.  The MiSTer waits by itself and reads no more of the file
        than that: while the job runs, whatever its Linux does in memory is in
        the kernels' times, since the machine's memory, a region of its own,
        is in the same DDR3 behind the same controller."""
        new = 'tail -c +%d %s/printer.txt | head -c %d' % (behind + 1, games, ROOM)
        return hil.ssh("n=0; while [ $n -lt %d ] && ! %s | grep -q 'END OF JOB'; do sleep 4; n=$((n+4)); done; %s"
                       % (seconds, new, new), capture=True).rstrip(b'\n').decode('latin-1')

    if not opts.get('running'):
        # the job on a copy of the expander disk, and the core started with it
        hil.scp_to(path, '/tmp/%s.txt' % JOB)
        hil.scp_to(os.path.join(ROOT, 'tools', 'py', 'expdisk.py'), '/tmp/expdisk.py')
        hil.ssh('cd %s && cp exp_disk.img bench_disk.img && (python3 /tmp/expdisk.py rm bench_disk.img STATION/%s '
                '> /dev/null 2>&1; python3 /tmp/expdisk.py puttext bench_disk.img STATION/%s /tmp/%s.txt)'
                % (games, JOB, JOB, JOB))
        mgl = ('<mistergamedescription><rbf>' + hil.RBF + '</rbf>'
               '<file delay="1" type="s" index="0" path="' + hil.IN_SET + 'bench_disk.img"/>'
               '<file delay="1" type="s" index="1" path="' + hil.IN_SET + 'drives.img"/>'
               '<file delay="1" type="s" index="2" path="' + hil.IN_SET + 'printer.txt"/>'
               '<file delay="1" type="f" index="1" path="' + hil.IN_SET + 'cos117.ios"/></mistergamedescription>')
        hil.ssh("cat > /tmp/xbench.mgl <<'EOF'\n%s\nEOF" % mgl)
        hil.ssh("test -f %s/printer.txt || %s" % (games, hil.NEW_PRINTER))
        hil.push_agent()
    # where the printing ends now: the file is its text and then empty lines
    size, before = (int(n) for n in hil.ssh(
        "python3 -c \"d = open('%s/printer.txt', 'rb').read(); print(len(d), len(d.rstrip(b'\\n')))\"" % games,
        capture=True).split())
    if size - before < ROOM:
        die('the printer\'s file is nearly full; `hil.py printed --new` empties it')
    if not opts.get('running'):
        print('starting the core and COS, about two and a half minutes of typing and waiting', flush=True)
        hil.run_play(240, STARTUP + SUBMIT, 'echo "load_core /tmp/xbench.mgl" > /dev/MiSTer_cmd')
    else:
        hil.push_agent()
        hil.run_play(30, SUBMIT)
    print('the job is submitted', flush=True)
    text = paper(before, opts.get('wait', 900))
    open(os.path.join(OUT, 'printed.txt'), 'w').write(text)
    if 'END OF JOB' not in text:
        die('the job has not ended after %d s (--wait); what it printed is in %s.  If that is nothing, COS '
            'did not get as far as taking the job: the keys are typed blind, at times that leave room '
            '(STARTUP in this script), and `hil.py shot` shows where the consoles stand'
            % (opts.get('wait', 900), os.path.join(OUT, 'printed.txt')))
    col = printed(src, want, text, 'hardware', True, lines)
    # the core's file: of several, the MiSTer takes the last by name
    col['core'] = hil.ssh('ls /media/fat/%s*.rbf | sort | tail -1' % hil.RBF, capture=True).decode().strip().split('/')[-1]
    spread(col)
    finish(src, [col], opts)


def main():
    commands = {'sim': cmd_sim, 'job': cmd_job, 'model': cmd_model, 'mister': cmd_mister, 'read': cmd_read,
                'compare': cmd_compare, 'list': cmd_list}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]](sys.argv[2:])


if __name__ == '__main__':
    main()
