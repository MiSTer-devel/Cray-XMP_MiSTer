# The cross-compilers for COS on the CRAY X-MP: Kevin Jordan's fork of the
# Amsterdam Compiler Kit, with the assembler, loader and library manager of
# his COS-Tools, which the kit calls, and cray-xmp-job, which runs a program
# they made on the CPU's reference model.  The image is built from the tools
# directory, for the model's sources:
#
#   docker build -t cray-ack -f tools/ack/Dockerfile tools
#   docker run --rm -v "$PWD":/work cray-ack ack -mcos -o hello.abs hello.c
#   docker run --rm -v "$PWD":/work cray-ack cray-xmp-job hello.abs
FROM rust:1-bookworm AS job
COPY Cargo.toml Cargo.lock /src/
COPY crates /src/crates
RUN cd /src && cargo build --release --locked -p cray-xmp-job

FROM debian:bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates bison flex lua5.3 lua-posix \
 && rm -rf /var/lib/apt/lists/*
# COS-Tools with three faults put right (cos-tools.patch).  The assembler
# moved the rest of a line up against a name that is too long with strcpy,
# whose two strings must not overlap: with this C library the line came out
# garbled and the kit's own C library did not assemble.  The record control
# words of a dataset were computed in 32 bits, and for a program of some
# lengths above 127 blocks the end of its record came out as an end of
# data.  And the loader let an address that wraps around (a symbol less a
# constant) carry into the register field of its instruction.  The loader
# also places blank common last, after all other blocks, as CRAY's loader
# does, and leaves it out of the binary, whose high limit takes it in: it
# wrote it out as zeros, and a program with a large table there (Cray
# Blitz's hash table) took 10 MB on the disk where it takes 3.
COPY ack/cos-tools.patch /src/cos-tools.patch
RUN git clone https://github.com/kej715/COS-Tools /src/COS-Tools \
 && cd /src/COS-Tools && git checkout 6600331 \
 && git apply /src/cos-tools.patch \
 && make cal dasm ldr lib && install -m 755 cal dasm ldr lib /usr/local/bin
# The kit, with a patch to its libraries and startup for COS (ack-cos.patch):
#
# - A dataset that is interactive (the input and output of a session at the
#   station) is read and written with COS's circular I/O requests, which
#   are the only ones it takes; the buffered I/O the library uses is
#   refused on it.  A read then returns a line at a time, and isatty says
#   such a dataset is a terminal, so stdout is buffered by lines.  Programs
#   that talk to the station need it, in C and in FORTRAN (the FORTRAN
#   runtime reads and writes through this library).
# - A program's startup asks COS for memory when the loader left it less
#   free for its heap and stack than it wants: 40,960 words, or what the
#   program says in a word of its own (long _heapwds in C).  A large
#   program got none and could not open a file.
# - Integers are multiplied, divided and their remainders taken exactly.
#   The kit did all three in floating point, where the machine divides by
#   a reciprocal that is close and not exact: 1,025,000 / 1,000 gave 1,024,
#   a number such as 131,070 was printed as 131060, and 1 % -3 was 0.
# - realloc copies what the old block holds.  It copied one block more,
#   past the end of a new block that is no larger in blocks than the old
#   one, which the next free ran into.
# - The startup clears blank common, which the binary no longer holds:
#   COS gives a program memory that is zero, but the control statement
#   processor ran in the same memory before it and leaves words there.
# - A read stops at the end of a file of a dataset (it took the flag for
#   one to be 4 where COS sets 2, and read on into the next file) and at
#   the end of the data that COS reports among the table's error flags (a
#   dataset not yet written gave an empty record, then an I/O error), and
#   it does not read the next record before it is asked for one; a write
#   after a read begins where the read stopped; and what was written is
#   ended before the dataset is opened again to go back in it (a rewind),
#   as at its close, where COS had nothing to read.  Together they let a
#   FORTRAN program read a file to its end and add to it, and read back
#   what it wrote.
# - _onattn(&flag) has the station's attention (/ATTENTION, BREAK) set a
#   word instead of ending the program, which goes on where it was: COS's
#   reprieve.  A program cannot otherwise see a line typed while it works,
#   since COS keeps a job that reads the session's input waiting for it.
# - memcpy and memset move whole words where they can, and a binary read
#   copies what the library has read in one piece: both went a byte at a
#   time, each byte through two calls.
RUN git clone https://github.com/kej715/ack /src/ack \
 && cd /src/ack && git checkout 03b8233
COPY ack/ack-cos.patch /src/ack-cos.patch
RUN cd /src/ack && git apply /src/ack-cos.patch \
 && ./cray-build.sh && ./cray-build.sh install \
 && rm -rf /tmp/ack-build
# COS-Tools' FORTRAN 77 cross-compiler (kftc) with its runtime and intrinsic
# libraries and the cft77 driver script, with a patch for the FORTRAN of
# older programs (the games in Cray-COS-Games; cos-tools-fortran.patch):
#
# - A Hollerith mode (-H) in which a character constant in a numeric
#   context is a Hollerith constant, left-justified and blank-filled in a
#   word, and one passed to a routine that is not intrinsic is passed as
#   words; a format held in an integer array; PRINT and READ with no list;
#   RETURN with an expression; CALL EXIT as STOP (it reached the C
#   library's exit with no status); a label ASSIGNed twice before it is
#   defined; A input into a word left-justified and blank-filled, as Cray
#   FORTRAN does it; formats of up to 256 descriptors; blanks inside the
#   descriptors of a format held in a variable.
# - Direct access records (REC= was parsed and ignored).  A direct access
#   file is held in memory while it is open, in pieces, so that it takes
#   the room of its records; units that open the same file share it.
# - BACKSPACE (it was parsed and did nothing): back over the record read
#   or written last, or after the end of the file back to before it, so
#   that a program can add to a file it read.  A slash in the format of a
#   READ reads the next record (it read on in the same one), also after
#   the last item.  An OPEN of a name no dataset can have (more than seven
#   characters) fails as one of a dataset that is not there does, for ERR=
#   and IOSTAT=; it stopped the program.
# - The bit functions AND, OR, XOR, NOT (with IAND, IOR, IEOR, COMPL) and
#   ISHFT are compiled in line, and so are the product of two integers
#   below 2**24 (larger ones go to the library) and MIN, MAX and ABS of
#   integers.  Each was a call.
# - The condition of an IF is compiled as jumps: a relation is a compare
#   and a jump, .AND. and .OR. jump as soon as the outcome is known
#   (jumps.c, a pass over the compiled program).  Each relation was made
#   a value, with a jump, and the result tested with another.
# - An octal or hexadecimal constant (O'17', X'FF') has all 64 bits; it
#   was cut to 32, and a mask of 40 bits came out as all ones.
# - A 64-bit DATA value is written whole (the compiler printed it as a
#   32-bit integer); a fresh record starts after a slash at the end of a
#   format (the line before it was printed again); the sign of ISIGN's
#   second argument is tested as the integer it is (as a real it raised a
#   floating point error); a variable that has only its implicit type gets
#   that type before its DATA values are converted (they were written out
#   unconverted, a character constant as its length); the result of a
#   character function keeps its storage for the whole call (every
#   reference to it got new storage, so the function could not read what
#   it had assigned); a formatted record is written without the blanks
#   that fill it out to 152 characters.
COPY ack/cos-tools-fortran.patch /src/cos-tools-fortran.patch
RUN cd /src/COS-Tools && git apply /src/cos-tools-fortran.patch \
 && make -C fortran && make -C fortran/runtime install && make -C fortran/intrinsic install \
 && install -m 755 fortran/kftc /usr/local/bin/kftc && install -m 755 fortran/cft77 /usr/local/bin/cft77
COPY --from=job /src/target/release/cray-xmp-job /usr/local/bin/cray-xmp-job
WORKDIR /work
