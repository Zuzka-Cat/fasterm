/* Microbenchmark: just Xlib/XCB setup with one fresh process per sample. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <X11/Xlib.h>
#include <xcb/xcb.h>
static long long now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (long long)t.tv_sec * 1000000000LL+t.tv_nsec; }
int main(int argc,char**argv) {
 if(argc!=2) return 2;
 long long t=now();
 if(!strcmp(argv[1],"xlib")){ Display *d=XOpenDisplay(0); if(!d)return 1; printf("%.6f\n",(now()-t)/1e6); XCloseDisplay(d); }
 else if(!strcmp(argv[1],"xcb")){ xcb_connection_t*c=xcb_connect(0,0);if(xcb_connection_has_error(c))return 1; printf("%.6f\n",(now()-t)/1e6); xcb_disconnect(c); }
 else return 2;
 return 0;
}
