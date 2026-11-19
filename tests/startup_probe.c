/* TEST-ONLY LD_PRELOAD probe: time startup to first frame or first text glyph.
 * Record timestamps without printf in hot path; report once via inherited pipe.
 * No terminal/runtime dependency on this file.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <time.h>
#include <string.h>
#include <X11/Xlib.h>
/* Xft development headers are optional; only opaque pointers are needed. */
#include <pty.h>
#include <locale.h>

static struct stamp { const char *name; uint64_t begin, end; } stamps[256];
static unsigned ns;
static int reported, saw_text, report_fd=-1;
static int target_text;
static uint64_t time_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec; }
static void add(const char *name, uint64_t a, uint64_t b) { unsigned i=__atomic_fetch_add(&ns,1,__ATOMIC_RELAXED); if(i < 256) stamps[i] = (struct stamp){name,a,b}; }
__attribute__((constructor)) static void init_probe(void) {
    const char *v=getenv("FASTST_BENCH_FD"); if(v) report_fd=atoi(v);
    target_text = (getenv("FASTST_BENCH_TARGET") && strcmp(getenv("FASTST_BENCH_TARGET"),"text")==0);
    uint64_t now=time_ns(); add("ldpreload_ctor",now,now);
}
#define TRACE_WRAP(T, name, params, args) \
T name params { \
  static T (*real) params; \
  if (!real) real=dlsym(RTLD_NEXT, #name); \
  uint64_t time_start=time_ns(); T out=real args; add(#name,time_start,time_ns()); return out; \
}
TRACE_WRAP(char *, setlocale, (int a, const char *b), (a,b))
TRACE_WRAP(Display *, XOpenDisplay, (const char *a), (a))
TRACE_WRAP(void *, XftFontOpenName, (Display *a, int b, const char *c), (a,b,c))
TRACE_WRAP(void *, XftFontOpenPattern, (Display *a, void *b), (a,b))
TRACE_WRAP(void *, FcFontMatch, (void*a,void*b,int*c), (a,b,c))
TRACE_WRAP(void *, FcNameParse, (const unsigned char*a), (a))
TRACE_WRAP(int, FcConfigSubstitute, (void*a,void*b,int c), (a,b,c))
TRACE_WRAP(Window, XCreateSimpleWindow, (Display*a,Window b,int c,int d,unsigned int e,unsigned int f,unsigned int g,unsigned long h,unsigned long i), (a,b,c,d,e,f,g,h,i))
TRACE_WRAP(int, XSelectInput, (Display*a,Window b,long c), (a,b,c))
TRACE_WRAP(GC, XCreateGC, (Display*a,Drawable b,unsigned long c,XGCValues*d), (a,b,c,d))
TRACE_WRAP(void *, XftDrawCreate, (Display*a,Drawable b,Visual*c,Colormap d), (a,b,c,d))
TRACE_WRAP(Atom, XInternAtom, (Display*a,const char*b,Bool c), (a,b,c))
TRACE_WRAP(Status, XSetWMProtocols, (Display*a,Window b,Atom*c,int d), (a,b,c,d))
TRACE_WRAP(int, XStoreName, (Display*a,Window b,const char*c), (a,b,c))
TRACE_WRAP(int, XMapWindow, (Display*a,Window b), (a,b))
TRACE_WRAP(Bool, XftColorAllocValue, (Display*a,const Visual*b,Colormap c,const void*d,void*e), (a,b,c,d,e))
TRACE_WRAP(pid_t, forkpty, (int*a,char*b,const struct termios*c,const struct winsize*d), (a,b,c,d))
static void report(void) {
    if(report_fd<0) return;
    char buf[16384]; size_t pos=0;
    for(unsigned i=0;i<ns;i++) {
        int n=snprintf(buf+pos,sizeof(buf)-pos,"%s %llu %llu\n",stamps[i].name,(unsigned long long)stamps[i].begin,(unsigned long long)stamps[i].end);
        if(n<0 || (size_t)n >= sizeof(buf)-pos) break;
        pos += n;
    }
    if(pos) (void)write(report_fd,buf,pos);
}
/* Text is present only once the terminal has rendered actual PTY output. */
void XftDrawString32(void *draw, void *color, void *font, int x, int y,
                     const uint32_t *str, int len) {
    static void (*real)(void*,void*,void*,int,int,const uint32_t*,int);
    if(!real) real=dlsym(RTLD_NEXT,"XftDrawString32");
    real(draw,color,font,x,y,str,len);
    saw_text=1;
}
int XFlush(Display*d) {
   static int (*real)(Display*);
   static int (*sync)(Display*,Bool);
   if(!real) real=dlsym(RTLD_NEXT,"XFlush");
   if(!sync) sync=dlsym(RTLD_NEXT,"XSync");
   uint64_t start=time_ns(); int out=real(d); add("XFlush",start,time_ns());
   if(!reported && (!target_text || saw_text)) {
      reported=1;
      start=time_ns(); sync(d,False); add("XSync_after_target_frame",start,time_ns());
      uint64_t now=time_ns(); add(target_text ? "first_text" : "first_frame",now,now);
      report();
   }
   return out;
}
