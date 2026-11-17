/* Winsock's error codes the classifier test needs, for a host without
 * winsock2.h: their values are fixed by the Windows ABI (check.sh checks
 * them against mingw-w64's winsock2.h when it is installed). */
#define WSAEACCES       10013
#define WSAEADDRINUSE   10048
#define WSAENETDOWN     10050
#define WSAENETUNREACH  10051
#define WSAENETRESET    10052
#define WSAECONNABORTED 10053
#define WSAECONNRESET   10054
#define WSAETIMEDOUT    10060
#define WSAECONNREFUSED 10061
#define WSAEHOSTUNREACH 10065
