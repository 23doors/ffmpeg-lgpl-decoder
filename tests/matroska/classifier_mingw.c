/* The classifier compiled for Windows with mingw-w64 against the real
 * network.h and winsock2.h (check.sh: compile only), and winsock's values in
 * wsa_codes.h checked against winsock2.h's. */
#include "config.h"
#include "libavformat/network.h"

#include "classifier_fn.c"

int classify(int err);
int classify(int err)
{
    return matroska_io_error_is_transient(err);
}

#include "wsa_codes_check.h"
