/* 0160's matroska_io_error_is_transient(), taken from the patched
 * matroskadec.c (check.sh writes it to classifier_fn.c), against the errors
 * a read over tcp and http fails with: the host's errno codes, and with
 * WINSOCK=1 also Windows' (winsock's codes, which tcp returns there:
 * ff_neterrno(), a failed connect's SO_ERROR). Exits non-zero when one is
 * classified wrong. */
#include "config.h"
#if WINSOCK
#undef HAVE_WINSOCK2_H
#define HAVE_WINSOCK2_H 1
#include "wsa_codes.h"
#endif
#include <errno.h>
#include <stdio.h>
#include "libavutil/error.h"

#include "classifier_fn.c"

static int fails;

static void expect(const char *name, int err, int transient)
{
    if (!matroska_io_error_is_transient(err) != !transient) {
        printf("%s (%d) %s transient\n", name, err, transient ? "is not" : "is");
        fails++;
    }
}

#define EXPECT(err, transient) expect(#err, err, transient)

int main(void)
{
    EXPECT(AVERROR_EXIT, 1);
    EXPECT(AVERROR(EIO), 1);
    EXPECT(AVERROR(ETIMEDOUT), 1);
    EXPECT(AVERROR(ECONNRESET), 1);
    EXPECT(AVERROR(ECONNREFUSED), 1);
    EXPECT(AVERROR(EPIPE), 1);
    EXPECT(AVERROR_HTTP_SERVER_ERROR, 1);
    EXPECT(AVERROR_HTTP_TOO_MANY_REQUESTS, 1);
    EXPECT(AVERROR_HTTP_NOT_FOUND, 0);
    EXPECT(AVERROR_HTTP_FORBIDDEN, 0);
    EXPECT(AVERROR_HTTP_UNAUTHORIZED, 0);
    EXPECT(AVERROR_INVALIDDATA, 0);
    EXPECT(AVERROR_EOF, 0);
    EXPECT(AVERROR(ENOMEM), 0);
#if WINSOCK
    EXPECT(AVERROR(WSAECONNREFUSED), 1);
    EXPECT(AVERROR(WSAECONNRESET), 1);
    EXPECT(AVERROR(WSAECONNABORTED), 1);
    EXPECT(AVERROR(WSAETIMEDOUT), 1);
    EXPECT(AVERROR(WSAENETDOWN), 1);
    EXPECT(AVERROR(WSAENETUNREACH), 1);
    EXPECT(AVERROR(WSAENETRESET), 1);
    EXPECT(AVERROR(WSAEHOSTUNREACH), 1);
    EXPECT(AVERROR(WSAEACCES), 0);
    EXPECT(AVERROR(WSAEADDRINUSE), 0);
#endif
    printf("%d wrong\n", fails);
    return fails != 0;
}
