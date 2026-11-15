/* hlsread: read an input with libavformat and report packets.
 * usage: hlsread URL [-o key=value]... [-stallint MS] [-maxtime S] [-q]
 *                    [-pace LEAD [-start S]]
 *   -stallint MS  the interrupt callback returns 1 once (for 50 ms) when no
 *                 packet came for MS ms: a transient control interrupt that
 *                 recovers; av_read_frame's AVERROR_EXIT is then read past
 *   -maxtime S    stop after S seconds of wall time
 *   -q            no per-packet lines for media streams
 *   -nofsi        no avformat_find_stream_info() (it reads seconds ahead)
 *   -pace LEAD    simulate a player of stream 0 (see below) that reads at
 *                 most LEAD s ahead; -start S: it starts with S s buffered
 * Prints per packet "pkt <t_wall> <stream> <pts_s> <size>" (subtitle packets
 * with their text), and a summary: packets per stream, a CRC of each
 * stream's packet data (crcN, the packets in order), the largest pts step
 * of stream 0, the result. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavutil/time.h>
#include <libavutil/opt.h>
#include <libavutil/crc.h>

static int64_t t0, last_pkt, int_until;

/* -pace: a player of stream 0 at real time that reads at most LEAD seconds
 * ahead of its position, jumps over gaps (as RMP takes a live gap) and
 * counts the time it waits for data (rebuffering) */
static double pace = -1, p_startbuf = -1, p_pos, p_wall, p_end = -1, p_rebuf, p_rebuf_since = -1;
static double gap_at[64], gap_to[64];
static int p_started, p_playing, n_gaps, g_next, p_stalls;

static double wall(void) { return (av_gettime_relative() - t0) / 1e6; }

static void player_update(double now)
{
    if (!p_playing) {
        if (p_started && p_end - p_pos >= 0.3) {
            if (p_rebuf_since >= 0) {
                p_rebuf += now - p_rebuf_since;
                printf("rebuffer %.3f s ends at %.3f (pos %.3f)\n", now - p_rebuf_since, now, p_pos);
                p_rebuf_since = -1;
            }
            p_playing = 1;
            p_wall = now;
        }
        return;
    }
    p_pos += now - p_wall;
    p_wall = now;
    while (g_next < n_gaps && p_pos >= gap_at[g_next]) {
        p_pos += gap_to[g_next] - gap_at[g_next];
        printf("player jumps %.3f s at %.3f\n", gap_to[g_next] - gap_at[g_next], now);
        g_next++;
    }
    if (p_pos >= p_end) {
        p_pos = p_end;
        p_playing = 0;
        p_stalls++;
        p_rebuf_since = now;
        printf("rebuffer starts at %.3f (pos %.3f)\n", now, p_pos);
    }
}

static void player_packet(double now, double pts)
{
    double end = pts + 0.04;
    if (p_end < 0) {
        p_pos = pts;
        p_end = end;
        return;
    }
    if (pts > p_end + 0.1 && n_gaps < 64) {
        if (!p_playing && p_pos >= p_end - 1e-6) {
            printf("player jumps %.3f s at %.3f\n", pts - p_end, now);
            p_pos = pts;
        } else {
            gap_at[n_gaps] = p_end;
            gap_to[n_gaps++] = pts;
        }
    }
    if (end > p_end)
        p_end = end;
    if (!p_started && p_end - p_pos >= (p_startbuf >= 0 ? p_startbuf : pace))
        p_started = 1;
}
static int stall_ms = -1, interrupts;

static int int_cb(void *opaque)
{
    int64_t now = av_gettime_relative();
    if (int_until && now < int_until)
        return 1;
    if (stall_ms >= 0 && !interrupts && last_pkt &&
        now - last_pkt > stall_ms * 1000LL) {
        interrupts++;
        int_until = now + 50000;
        fprintf(stderr, "interrupt at %.3f\n", (now - t0) / 1e6);
        return 1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    AVFormatContext *s = NULL;
    AVDictionary *opts = NULL;
    AVPacket *pkt = av_packet_alloc();
    double maxtime = 60;
    int quiet = 0, nofsi = 0, ret, n[16] = { 0 }, exits = 0;
    uint32_t crc[16] = { 0 };
    const AVCRC *crc_table = av_crc_get_table(AV_CRC_32_IEEE_LE);
    double prev0 = -1, maxstep0 = 0;
    const char *url = argv[1];

    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            char *kv = argv[++i], *eq = strchr(kv, '=');
            if (!eq) {
                fprintf(stderr, "-o %s: key=value\n", kv);
                return 2;
            }
            *eq = 0;
            av_dict_set(&opts, kv, eq + 1, 0);
        } else if (!strcmp(argv[i], "-stallint")) {
            stall_ms = atoi(argv[++i]);
        } else if (!strcmp(argv[i], "-maxtime")) {
            maxtime = atof(argv[++i]);
        } else if (!strcmp(argv[i], "-start")) {
            p_startbuf = atof(argv[++i]);
        } else if (!strcmp(argv[i], "-pace")) {
            pace = atof(argv[++i]);
        } else if (!strcmp(argv[i], "-nofsi")) {
            nofsi = 1;
        } else if (!strcmp(argv[i], "-q")) {
            quiet = 1;
        }
    }
    av_log_set_level(getenv("LOGLEVEL") ? atoi(getenv("LOGLEVEL")) : AV_LOG_INFO);
    t0 = av_gettime_relative();
    s = avformat_alloc_context();
    s->interrupt_callback.callback = int_cb;
    if ((ret = avformat_open_input(&s, url, NULL, &opts)) < 0) {
        printf("open failed: %s\n", av_err2str(ret));
        return 1;
    }
    {
        const AVDictionaryEntry *e = NULL;
        while ((e = av_dict_iterate(opts, e)))
            printf("option not used: %s=%s\n", e->key, e->value);
    }
    if (!nofsi && (ret = avformat_find_stream_info(s, NULL)) < 0)
        printf("find_stream_info: %s\n", av_err2str(ret));
    printf("opened at %.3f, %d streams\n", (av_gettime_relative() - t0) / 1e6, s->nb_streams);
    while (1) {
        double now = (av_gettime_relative() - t0) / 1e6;
        if (now > maxtime) {
            printf("maxtime\n");
            break;
        }
        if (pace > 0) {
            player_update(now);
            if (p_started && p_end - p_pos >= pace) {
                av_usleep(10000);
                continue;
            }
        }
        ret = av_read_frame(s, pkt);
        if (ret == AVERROR_EXIT) {
            exits++;
            printf("read: AVERROR_EXIT at %.3f, reading on\n", now);
            av_usleep(60000);
            continue;
        }
        if (ret < 0) {
            printf("end: %s at %.3f\n", av_err2str(ret), now);
            break;
        }
        last_pkt = av_gettime_relative();
        {
            AVStream *st = s->streams[pkt->stream_index];
            /* the dts where there is no pts (hls gives an ID3-timestamped
             * stream's packets only a dts) */
            int64_t ts = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
            double pts = ts == AV_NOPTS_VALUE ? -1 : ts * av_q2d(st->time_base);
            if (pkt->stream_index < 16) {
                n[pkt->stream_index]++;
                crc[pkt->stream_index] = av_crc(crc_table, crc[pkt->stream_index], pkt->data, pkt->size);
            }
            if (st->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE) {
                printf("pkt %.3f %d %.3f %d \"", now, pkt->stream_index, pts, pkt->size);
                for (int i = 0; i < pkt->size; i++)
                    if (pkt->data[i] == '\n')
                        printf("\\n");
                    else
                        putchar(pkt->data[i]);
                printf("\"\n");
            } else if (!quiet) {
                printf("pkt %.3f %d %.3f %d\n", now, pkt->stream_index, pts, pkt->size);
            }
            if (pace > 0 && pkt->stream_index == 0 && pkt->dts != AV_NOPTS_VALUE) {
                player_update(wall());
                player_packet(wall(), pkt->dts * av_q2d(st->time_base));
            }
            if (pkt->stream_index == 0 && pts >= 0) {
                if (prev0 >= 0 && pts - prev0 > maxstep0)
                    maxstep0 = pts - prev0;
                prev0 = pts;
            }
        }
        av_packet_unref(pkt);
    }
    printf("summary: exits=%d", exits);
    for (int i = 0; i < (int)s->nb_streams && i < 16; i++)
        printf(" s%d=%d", i, n[i]);
    for (int i = 0; i < (int)s->nb_streams && i < 16; i++)
        printf(" crc%d=%08x", i, crc[i]);
    printf(" last_pts0=%.3f maxstep0=%.3f", prev0, maxstep0);
    if (pace > 0)
        printf(" stalls=%d rebuffer=%.3f", p_stalls, p_rebuf);
    printf("\n");
    avformat_close_input(&s);
    av_packet_free(&pkt);
    return 0;
}
