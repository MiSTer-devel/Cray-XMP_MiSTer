#!/usr/bin/env python3
"""Make the boot file of the CRAY X-MP core from the kernel of the I/O
Subsystem and its boot tape.

  mkboot.py KERNEL TAPE OUT [--quick] [--poke PARCEL=VALUE]...

KERNEL is the kernel as parcels, high byte first (iop_kern.bin of the COS 1.17
set); TAPE is the boot tape in .tap format (boot_tape.tap).  The core's menu
loads OUT into memory; rtl/mister/xmp_boot.v describes the format and checks
it before every start.

The core's I/O Subsystem has two I/O Processors, the MIOP and the BIOP, and
the COS 1.17 software was recovered configured for three: it waits for the
XIOP for ever.  The boot tape of that software is changed in the six parcels
of TWO_IOPS on its way into the file; another tape is taken as it is.

For simulations: --quick leaves out what only takes time (the kernel's test of
Local Memory, most of its test of Buffer Memory, and 499 of the 500 passes of
the BIOP's test of each disk drive), and --poke changes a parcel of the kernel
(both numbers hexadecimal).
"""
import struct
import sys

MEMORY = 131072     # bytes of a Local Memory, which the kernel is filled up to
MASK = (1 << 64) - 1
RECORD = 4096       # bytes of a record of the boot tape

# What is changed on the boot tape for two I/O Processors: the byte of the
# tape's first file, the parcel that is there and the parcel that is written.
# The reference model has the same table (tools/crates/ios/src/system.rs) and
# so have the simulations (sim/harness/ios_media.h).
TWO_IOPS = (
    (0x00024, 0x009B, 0x0000),   # overlay AMAP, parcel 0x12: no section for IOP 3, so it is not dead started
    (0x0004A, 0x801B, 0x0000),   # AMAP, the MIOP's channels 12 and 13: no link to IOP 3
    (0x0004C, 0x801B, 0x0000),
    (0x000A6, 0x801B, 0x0000),   # AMAP, the BIOP's channels 12 and 13
    (0x000A8, 0x801B, 0x0000),
    (0x03022, 0x700A, 0x700F),   # overlay CDEM, parcel 0x1F of its code: a tape packet (type D) is released
                                 # (P + 15) and not passed to IOP 3 (P + 10)
)


def two_iops(tape):
    """The boot tape (.tap) of the COS 1.17 software for two I/O Processors,
    or None if `tape` is not that software's.  A tape that was changed before
    comes back the same."""
    tape = bytearray(tape)
    for offset, old, new in TWO_IOPS:
        # a record has its length, four bytes, before and after it
        at = offset + 4 + 8 * (offset // RECORD)
        if bytes(tape[at:at + 2]) not in (struct.pack('>H', old), struct.pack('>H', new)):
            return None
        tape[at:at + 2] = struct.pack('>H', new)
    return bytes(tape)


def words(data):
    data += bytes(-len(data) % 8)
    return struct.unpack('>%dQ' % (len(data) // 8), data)


def check_sum(data):
    total = 0
    for word in words(data):
        total = (((total << 1) | (total >> 63)) + word) & MASK
    return total


def boot_file(kernel, tape):
    if len(kernel) > MEMORY:
        raise ValueError('the kernel is larger than a Local Memory')
    if len(tape) >= 1 << 24:
        raise ValueError('the tape is larger than 16 million bytes')
    body = kernel + bytes(MEMORY - len(kernel)) + tape + bytes(-len(tape) % 8)
    head = b'XMPBOOT2' + struct.pack('>QQQ', len(kernel), len(tape), check_sum(body)) + bytes(32)
    return head + body


def main(argv):
    names, pokes, quick = [], [], False
    args = iter(argv)
    for a in args:
        if a == '--quick':
            quick = True
        elif a == '--poke':
            parcel, value = next(args).split('=')
            pokes.append((int(parcel, 16), int(value, 16)))
        else:
            names.append(a)
    if len(names) != 3:
        sys.exit(__doc__)
    kernel = bytearray(open(names[0], 'rb').read())
    tape = bytearray(open(names[1], 'rb').read())
    if quick:
        pokes += [(0x42B7, 0x0200), (0x43DA, 0)]
        # overlay INDD29 on the tape: A = 500 becomes A = 1.  Byte 0x8C20 of the
        # first file, behind nine record lengths of four bytes.
        at = 0x8C20 + 4 + 8 * (0x8C20 // RECORD)
        if tape[at:at + 2] != b'\x11\xf4':
            sys.exit('mkboot: this tape does not have the drive test where --quick expects it')
        tape[at:at + 2] = b'\x10\x01'
    for parcel, value in pokes:
        if 2 * parcel + 1 >= len(kernel):
            sys.exit('mkboot: parcel %x is not in the kernel' % parcel)
        kernel[2 * parcel:2 * parcel + 2] = struct.pack('>H', value)
    tape = two_iops(tape) or bytes(tape)
    try:
        out = boot_file(bytes(kernel), tape)
    except ValueError as e:
        sys.exit('mkboot: %s' % e)
    open(names[2], 'wb').write(out)
    print('%s: %d bytes (kernel %d, tape %d)' % (names[2], len(out), len(kernel), len(tape)))


if __name__ == '__main__':
    main(sys.argv[1:])
