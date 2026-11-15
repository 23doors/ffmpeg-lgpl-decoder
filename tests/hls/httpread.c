/* httpread: read an http input byte by byte through avio, for the http.c
 * checks (the requests a read or a seek makes, what comes back).
 * usage: httpread URL [-o key=value]... [-direct] [-get NAME]... CMD...
 *   -o key=value  an option of the open (http's)
 *   -direct       AVIO_FLAG_DIRECT: each read and seek goes to http as it is
 *                 (no avio buffer, no read-ahead in place of a seek)
 *   -get NAME     print the protocol's option NAME after the commands
 *                 ("get NAME=value")
 * CMD:
 *   r:N   read N bytes (or up to the end or an error): "read N got M
 *         crc=C end=E" (E: ok, eof or the error)
 *   ra    read to the end or an error, the same line
 *   s:OFF seek to OFF (SEEK_SET): "seek OFF ret=R" (R the result or the
 *         error)
 * Ends with "summary bytes=<all read> crc=<of all read> open=<ok|error>". */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avio.h>
#include <libavutil/crc.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>

static const AVCRC *crc_tab;
static uint32_t crc_all;
static int64_t total;

static void do_read(AVIOContext *pb, int64_t want)
{
    uint8_t buf[4096];
    uint32_t crc = 0;
    int64_t got = 0;
    int ret = 0;
    while (want < 0 || got < want) {
        int n = want < 0 || want - got > (int64_t)sizeof(buf) ? (int)sizeof(buf) : (int)(want - got);
        ret = avio_read(pb, buf, n);
        if (ret <= 0)
            break;
        crc = av_crc(crc_tab, crc, buf, ret);
        crc_all = av_crc(crc_tab, crc_all, buf, ret);
        got += ret;
        total += ret;
    }
    printf("read %lld got %lld crc=%08x end=%s\n", (long long)want, (long long)got, crc,
           ret > 0 ? "ok" : ret == 0 || ret == AVERROR_EOF ? "eof" : av_err2str(ret));
}

int main(int argc, char **argv)
{
    AVDictionary *opts = NULL;
    AVIOContext *pb = NULL;
    const char *get[8];
    int n_get = 0, flags = AVIO_FLAG_READ, i, ret;

    if (argc < 2) {
        fprintf(stderr, "usage: httpread URL [-o key=value]... [-direct] [-get NAME]... CMD...\n");
        return 2;
    }
    crc_tab = av_crc_get_table(AV_CRC_32_IEEE_LE);
    for (i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            char *kv = argv[++i], *eq = strchr(kv, '=');
            if (!eq)
                return 2;
            *eq = 0;
            av_dict_set(&opts, kv, eq + 1, 0);
        } else if (!strcmp(argv[i], "-direct")) {
            flags |= AVIO_FLAG_DIRECT;
        } else if (!strcmp(argv[i], "-get") && i + 1 < argc && n_get < 8) {
            get[n_get++] = argv[++i];
        } else
            break;
    }
    av_log_set_level(AV_LOG_VERBOSE);
    ret = avio_open2(&pb, argv[1], flags, NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        printf("open failed: %s\n", av_err2str(ret));
        printf("summary bytes=0 crc=00000000 open=error\n");
        return 1;
    }
    for (; i < argc; i++) {
        const char *c = argv[i];
        if (!strncmp(c, "r:", 2))
            do_read(pb, strtoll(c + 2, NULL, 10));
        else if (!strcmp(c, "ra"))
            do_read(pb, -1);
        else if (!strncmp(c, "s:", 2)) {
            int64_t off = strtoll(c + 2, NULL, 10), r = avio_seek(pb, off, SEEK_SET);
            if (r < 0)
                printf("seek %lld ret=%s\n", (long long)off, av_err2str((int)r));
            else
                printf("seek %lld ret=%lld\n", (long long)off, (long long)r);
        } else {
            fprintf(stderr, "unknown command %s\n", c);
            return 2;
        }
    }
    for (int k = 0; k < n_get; k++) {
        uint8_t *v = NULL;
        if (av_opt_get(pb, get[k], AV_OPT_SEARCH_CHILDREN, &v) >= 0)
            printf("get %s=%s\n", get[k], v ? (char *)v : "");
        else
            printf("get %s: none\n", get[k]);
        av_free(v);
    }
    printf("summary bytes=%lld crc=%08x open=ok\n", (long long)total, crc_all);
    avio_closep(&pb);
    return 0;
}
