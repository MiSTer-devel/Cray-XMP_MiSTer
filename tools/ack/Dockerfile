# The cross-compilers for COS on the CRAY X-MP: Kevin Jordan's fork of the
# Amsterdam Compiler Kit, with the assembler, loader and library manager of
# his COS-Tools, which the kit calls.
#
#   docker build -t cray-ack tools/ack
#   docker run --rm -v "$PWD":/work cray-ack ack -mcos -o hello.abs hello.c
FROM debian:bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates bison flex lua5.3 lua-posix \
 && rm -rf /var/lib/apt/lists/*
# The assembler moves the rest of a line up against a name that is too long
# with strcpy, whose two strings must not overlap.  With this C library the
# line comes out garbled, and the kit's own C library does not assemble
# (OPERAND FIELD ERROR in flushbuf).
RUN git clone https://github.com/kej715/COS-Tools /src/COS-Tools \
 && cd /src/COS-Tools && git checkout 6600331 \
 && sed -i 's/strcpy(start + MAX_NAME_LENGTH, s);/memmove(start + MAX_NAME_LENGTH, s, strlen(s) + 1);/' parse.c \
 && make cal dasm ldr lib && install -m 755 cal dasm ldr lib /usr/local/bin
# The kit, with a patch to its C library and startup for COS.  A dataset
# that is interactive (the input and output of a session at the station)
# is read and written with COS's circular I/O requests, which are the only
# ones it takes; the buffered I/O the library uses is refused on it.  A
# read then returns a line at a time, and isatty says such a dataset is a
# terminal, so stdout is buffered by lines.  Programs that talk to the
# station need it, in C and in FORTRAN (the FORTRAN runtime reads and
# writes through this library).  And a program's startup asks COS for
# memory when the loader left it less than 40,960 words free for its heap
# and stack: a large program got none and could not open a file.
RUN git clone https://github.com/kej715/ack /src/ack \
 && cd /src/ack && git checkout 03b8233
COPY ack-cos.patch /src/ack-cos.patch
RUN cd /src/ack && git apply /src/ack-cos.patch \
 && ./cray-build.sh && ./cray-build.sh install \
 && rm -rf /tmp/ack-build
# COS-Tools' FORTRAN 77 cross-compiler (kftc) with its runtime and intrinsic
# libraries and the cft77 driver script, with a patch for the FORTRAN of
# older programs (the games in Cray-COS-Games): a Hollerith mode
# (-H) in which a character constant in a numeric context is a Hollerith
# constant, left-justified and blank-filled in a word, and one passed to a
# routine that is not intrinsic is passed as words; a format held in an
# integer array; PRINT and READ with no list; RETURN with an expression;
# CALL EXIT as STOP (it reached the C library's exit with no status); a
# label ASSIGNed twice before it is defined; A input into a word
# left-justified and blank-filled, as Cray FORTRAN does it; direct access
# records (REC= was parsed and ignored: a direct access file is now held in
# memory while it is open); formats of up to 256 descriptors; blanks
# inside the descriptors of a format held in a variable.  The patch
# also writes a 64-bit DATA value whole (the compiler printed it as a
# 32-bit integer), starts a fresh record after a slash at the end of a
# format (the line before it was printed again), tests the sign of
# ISIGN's second argument as the integer it is (as a real it raised a
# floating point error), and gives a variable that has only its implicit
# type that type before its DATA values are converted (they were written
# out unconverted, a character constant as its length).  And the result of
# a character function keeps its storage for the whole call: every
# reference to it got new storage, so the function could not read what it
# had assigned.  A formatted record is written without the blanks that
# fill it out to 152 characters.
COPY cos-tools-fortran.patch /src/cos-tools-fortran.patch
RUN cd /src/COS-Tools && git apply /src/cos-tools-fortran.patch \
 && make -C fortran && make -C fortran/runtime install && make -C fortran/intrinsic install \
 && install -m 755 fortran/kftc /usr/local/bin/kftc && install -m 755 fortran/cft77 /usr/local/bin/cft77
WORKDIR /work
