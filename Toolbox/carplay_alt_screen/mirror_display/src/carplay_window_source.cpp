#include "carplay_window_source.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

#define SCREEN_DISPLAY_MANAGER_CONTEXT 8
#define SCREEN_WINDOW_MANAGER_CONTEXT 1
#define SCREEN_PROPERTY_BUFFER_SIZE 5
#define SCREEN_PROPERTY_FORMAT 14
#define SCREEN_PROPERTY_POINTER 34
#define SCREEN_PROPERTY_RENDER_BUFFERS 37
#define SCREEN_PROPERTY_SIZE 40
#define SCREEN_PROPERTY_STRIDE 44
#define SCREEN_PROPERTY_USAGE 48
#define SCREEN_PROPERTY_ID 87
#define SCREEN_PROPERTY_WINDOW_COUNT 108
#define SCREEN_PROPERTY_WINDOWS 109
#define SCREEN_FORMAT_RGBA8888 8
#define SCREEN_USAGE_READ (1 << 1)
#define SCREEN_USAGE_NATIVE (1 << 3)

CarPlayWindowSource::CarPlayWindowSource(int window_id, bool verbose)
    : target_id_(window_id), verbose_(verbose), lib_(0), ctx_(0), window_(0), pixmap_(0), buffer_(0), pixels_(0), width_(0), height_(0), stride_(0), scan_attempts_(0), read_failures_(0), create_context_(0), destroy_context_(0), get_context_iv_(0), get_context_pv_(0), get_window_iv_(0), create_pixmap_(0), destroy_pixmap_(0), set_pixmap_iv_(0), create_pixmap_buffer_(0), get_pixmap_pv_(0), get_buffer_pv_(0), get_buffer_iv_(0), read_window_(0) {}
CarPlayWindowSource::~CarPlayWindowSource() { shutdown(); }
unsigned long long CarPlayWindowSource::now_us() const { struct timeval tv; if (gettimeofday(&tv, 0) != 0) return 0; return (unsigned long long)(unsigned long)tv.tv_sec * 1000000ULL + (unsigned long long)(unsigned long)tv.tv_usec; }
bool CarPlayWindowSource::should_log_scan() const { return scan_attempts_ == 1u || (verbose_ && (scan_attempts_ % 50u) == 0u); }

bool CarPlayWindowSource::open_api() {
    lib_ = dlopen("libscreen.so.1", RTLD_LAZY); if (!lib_) lib_ = dlopen("libscreen.so", RTLD_LAZY);
    if (!lib_) { fprintf(stderr, "source: cannot load libscreen\n"); return false; }
    create_context_=(create_context_fn)dlsym(lib_,"screen_create_context"); destroy_context_=(destroy_context_fn)dlsym(lib_,"screen_destroy_context"); get_context_iv_=(get_context_iv_fn)dlsym(lib_,"screen_get_context_property_iv"); get_context_pv_=(get_context_pv_fn)dlsym(lib_,"screen_get_context_property_pv"); get_window_iv_=(get_window_iv_fn)dlsym(lib_,"screen_get_window_property_iv"); create_pixmap_=(create_pixmap_fn)dlsym(lib_,"screen_create_pixmap"); destroy_pixmap_=(destroy_pixmap_fn)dlsym(lib_,"screen_destroy_pixmap"); set_pixmap_iv_=(set_pixmap_iv_fn)dlsym(lib_,"screen_set_pixmap_property_iv"); create_pixmap_buffer_=(create_pixmap_buffer_fn)dlsym(lib_,"screen_create_pixmap_buffer"); get_pixmap_pv_=(get_pixmap_pv_fn)dlsym(lib_,"screen_get_pixmap_property_pv"); get_buffer_pv_=(get_buffer_pv_fn)dlsym(lib_,"screen_get_buffer_property_pv"); get_buffer_iv_=(get_buffer_iv_fn)dlsym(lib_,"screen_get_buffer_property_iv"); read_window_=(read_window_fn)dlsym(lib_,"screen_read_window");
    if (!create_context_||!destroy_context_||!get_context_iv_||!get_context_pv_||!get_window_iv_||!create_pixmap_||!destroy_pixmap_||!set_pixmap_iv_||!create_pixmap_buffer_||!get_pixmap_pv_||!get_buffer_pv_||!get_buffer_iv_||!read_window_) { fprintf(stderr,"source: required Screen API missing create=%p destroy=%p ctx_iv=%p ctx_pv=%p win_iv=%p pixmap=%p pixbuf=%p read_window=%p\n",(void*)create_context_,(void*)destroy_context_,(void*)get_context_iv_,(void*)get_context_pv_,(void*)get_window_iv_,(void*)create_pixmap_,(void*)create_pixmap_buffer_,(void*)read_window_); return false; }
    return true;
}

bool CarPlayWindowSource::init() {
    shutdown(); if (!open_api()) return false;
    errno=0;
    if (create_context_(&ctx_,SCREEN_WINDOW_MANAGER_CONTEXT)!=0||!ctx_) { const int wm_errno=errno; ctx_=0; errno=0; if (create_context_(&ctx_,SCREEN_DISPLAY_MANAGER_CONTEXT)!=0||!ctx_) { fprintf(stderr,"source: manager-capable Screen context failed window_manager_errno=%d display_manager_errno=%d\n",wm_errno,errno); shutdown(); return false; } fprintf(stderr,"source: WINDOW_MANAGER_CONTEXT rejected errno=%d; using DISPLAY_MANAGER_CONTEXT fallback\n",wm_errno); }
    else fprintf(stderr,"source: WINDOW_MANAGER_CONTEXT ready\n");
    scan_attempts_=0; read_failures_=0; return true;
}
void CarPlayWindowSource::release_capture_buffer(){ pixels_=0; buffer_=0; stride_=0; if(pixmap_&&destroy_pixmap_)destroy_pixmap_(pixmap_); pixmap_=0; }

bool CarPlayWindowSource::find_window(){
    if(!ctx_)return false; ++scan_attempts_; const bool log_scan=should_log_scan(); int count=0; errno=0; const int count_rc=get_context_iv_(ctx_,SCREEN_PROPERTY_WINDOW_COUNT,&count); const int count_errno=errno;
    if(count_rc!=0||count<=0){ if(log_scan)fprintf(stderr,"source: window census attempt=%u rc=%d count=%d errno=%d target_id=%d\n",scan_attempts_,count_rc,count,count_errno,target_id_); return false; }
    if(count>128)count=128; void *wins[128]; memset(wins,0,sizeof(wins)); errno=0; const int list_rc=get_context_pv_(ctx_,SCREEN_PROPERTY_WINDOWS,wins); const int list_errno=errno;
    if(list_rc!=0){ if(log_scan)fprintf(stderr,"source: window list read attempt=%u rc=%d count=%d errno=%d target_id=%d\n",scan_attempts_,list_rc,count,list_errno,target_id_); return false; }
    if(log_scan)fprintf(stderr,"source: window census attempt=%u rc=0 count=%d target_id=%d\n",scan_attempts_,count,target_id_);
    for(int i=0;i<count;++i){ int id=-1; int size[2]={0,0}; if(!wins[i])continue; errno=0; const int id_rc=get_window_iv_(wins[i],SCREEN_PROPERTY_ID,&id); const int id_errno=errno; errno=0; const int size_rc=get_window_iv_(wins[i],SCREEN_PROPERTY_SIZE,size); const int size_errno=errno;
        if(log_scan||id==target_id_)fprintf(stderr,"source: window[%d] attempt=%u handle=%p id_rc=%d id=%d id_errno=%d size_rc=%d size=%dx%d size_errno=%d%s\n",i,scan_attempts_,wins[i],id_rc,id,id_errno,size_rc,size[0],size[1],size_errno,(id_rc==0&&id==target_id_)?" [target]":"");
        if(id_rc!=0||id!=target_id_||size_rc!=0||size[0]<=0||size[1]<=0)continue;
        if(window_!=wins[i]||width_!=size[0]||height_!=size[1]){ release_capture_buffer(); window_=wins[i]; width_=size[0]; height_=size[1]; fprintf(stderr,"source: bound CarPlay window id=%d handle=%p size=%dx%d attempt=%u\n",target_id_,window_,width_,height_,scan_attempts_); if(!create_capture_buffer()){window_=0;width_=height_=0;return false;} }
        return true;
    }
    if(log_scan)fprintf(stderr,"source: target window id=%d not found attempt=%u count=%d\n",target_id_,scan_attempts_,count); if(window_)fprintf(stderr,"source: target window id=%d disappeared; rebinding\n",target_id_); window_=0; release_capture_buffer(); return false;
}

bool CarPlayWindowSource::create_capture_buffer(){
    if(!window_||width_<=0||height_<=0)return false; if(create_pixmap_(&pixmap_,ctx_)!=0||!pixmap_){fprintf(stderr,"source: screen_create_pixmap failed errno=%d\n",errno);return false;}
    const int usage=SCREEN_USAGE_READ|SCREEN_USAGE_NATIVE; const int format=SCREEN_FORMAT_RGBA8888; int size[2]={width_,height_};
    if(set_pixmap_iv_(pixmap_,SCREEN_PROPERTY_USAGE,&usage)!=0||set_pixmap_iv_(pixmap_,SCREEN_PROPERTY_FORMAT,&format)!=0||set_pixmap_iv_(pixmap_,SCREEN_PROPERTY_BUFFER_SIZE,size)!=0||create_pixmap_buffer_(pixmap_)!=0||get_pixmap_pv_(pixmap_,SCREEN_PROPERTY_RENDER_BUFFERS,&buffer_)!=0||!buffer_||get_buffer_pv_(buffer_,SCREEN_PROPERTY_POINTER,(void**)&pixels_)!=0||!pixels_||get_buffer_iv_(buffer_,SCREEN_PROPERTY_STRIDE,&stride_)!=0||stride_<width_*4){fprintf(stderr,"source: capture pixmap setup failed size=%dx%d stride=%d errno=%d\n",width_,height_,stride_,errno);release_capture_buffer();return false;}
    fprintf(stderr,"source: capture buffer ready id=%d size=%dx%d stride=%d screen_format=8 cpu_format=BGRA8888\n",target_id_,width_,height_,stride_); return true;
}

bool CarPlayWindowSource::read_frame(VideoFrame *frame){
    if(!frame||!ctx_)return false; if(!window_||!pixmap_){if(!find_window())return false;} errno=0;
    if(read_window_(window_,buffer_,0,0,0)!=0){++read_failures_; if(read_failures_==1u||(verbose_&&(read_failures_%30u)==0u))fprintf(stderr,"source: screen_read_window id=%d handle=%p failed errno=%d failures=%u; rebinding\n",target_id_,window_,errno,read_failures_); window_=0; release_capture_buffer(); return false;}
    if(read_failures_){fprintf(stderr,"source: screen_read_window recovered id=%d after_failures=%u\n",target_id_,read_failures_);read_failures_=0;}
    frame->data=pixels_; frame->width=width_; frame->height=height_; frame->stride=stride_; frame->format=PIXEL_FORMAT_BGRA8888; frame->timestamp_us=now_us(); return true;
}
void CarPlayWindowSource::shutdown(){window_=0;release_capture_buffer();if(ctx_&&destroy_context_)destroy_context_(ctx_);ctx_=0;if(lib_)dlclose(lib_);lib_=0;create_context_=0;destroy_context_=0;get_context_iv_=0;get_context_pv_=0;get_window_iv_=0;create_pixmap_=0;destroy_pixmap_=0;set_pixmap_iv_=0;create_pixmap_buffer_=0;get_pixmap_pv_=0;get_buffer_pv_=0;get_buffer_iv_=0;read_window_=0;width_=height_=stride_=0;scan_attempts_=0;read_failures_=0;}
