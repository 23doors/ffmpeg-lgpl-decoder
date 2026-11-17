/* mkvseek: opens URL, reads its packets up to -read seconds, then makes each
 * -seek in turn (AVSEEK_FLAG_BACKWARD on the default stream, as a player
 * does), sleeping -pause ms before each, and reports per seek:
 *
 *   seek T ret=R                    av_seek_frame's result (0 or an error)
 *   landed T pts=P bytes=B          the first packet after a seek that
 *                                   succeeded: its time, and the bytes read
 *                                   from the seek's start to it
 *   noland T err=E                  no packet after it (the read's error)
 *
 * usage: mkvseek URL [-o KEY=VALUE]... [-read S] [-pause MS] -seek T [-seek T]...
 *   -o  an open option (http's reconnect options, as a player passes them)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>

static double pkt_seconds(const AVFormatContext *s, const AVPacket *pkt)
{
    int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    return ts == AV_NOPTS_VALUE ? -1 : ts * av_q2d(s->streams[pkt->stream_index]->time_base);
}

int main(int argc, char **argv)
{
    AVFormatContext *s = NULL;
    AVPacket *pkt = av_packet_alloc();
    AVDictionary *opts = NULL;
    double read_to = 2;
    int ret, i;

    if (argc < 2) {
        fprintf(stderr, "usage: mkvseek URL [-read S] [-pause MS] -seek T ...\n");
        return 2;
    }
    av_log_set_level(AV_LOG_VERBOSE);
    for (i = 2; i + 1 < argc; i += 2)
        if (!strcmp(argv[i], "-o"))
            av_dict_parse_string(&opts, argv[i + 1], "=", "", 0);
    ret = avformat_open_input(&s, argv[1], NULL, &opts);
    av_dict_free(&opts);
    if (ret < 0) {
        printf("open err=%s\n", av_err2str(ret));
        return 1;
    }
    for (i = 2; i + 1 < argc; i += 2)
        if (!strcmp(argv[i], "-read"))
            read_to = atof(argv[i + 1]);
    while ((ret = av_read_frame(s, pkt)) >= 0) {
        double t = pkt_seconds(s, pkt);
        av_packet_unref(pkt);
        if (t >= read_to)
            break;
    }
    printf("read to %.3f ret=%d\n", read_to, ret);
    fflush(stdout);

    for (i = 2; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "-pause")) {
            usleep(atoi(argv[i + 1]) * 1000);
        } else if (!strcmp(argv[i], "-seek")) {
            double target = atof(argv[i + 1]);
            int64_t before = s->pb->bytes_read;
            ret = av_seek_frame(s, -1, (int64_t)(target * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
            printf("seek %.3f ret=%d\n", target, ret);
            if (ret >= 0) {
                ret = av_read_frame(s, pkt);
                if (ret >= 0)
                    printf("landed %.3f pts=%.3f bytes=%lld\n", target, pkt_seconds(s, pkt),
                           (long long)(s->pb->bytes_read - before));
                else
                    printf("noland %.3f err=%s\n", target, av_err2str(ret));
                av_packet_unref(pkt);
            }
            /* a player clears what the failed I/O left before it reads on */
            s->pb->error = 0;
            s->pb->eof_reached = 0;
            fflush(stdout);
        }
    }
    av_packet_free(&pkt);
    avformat_close_input(&s);
    return 0;
}
