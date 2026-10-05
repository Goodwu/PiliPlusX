/* No-window capability probe. Compile-only until Lead authorizes runtime.
 * Private ABI header needs only mpv public headers, never libplacebo layout.
 * Optional argv[1] loads a local clip; no argument probes empty render only.
 * This does not model CA/Metal output or establish visible HDR acceptance. */
#include <assert.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <malloc/malloc.h>
#include "mpv/client.h"
#include "mpv/render_gl.h"
#include "video/out/gpu_next/libmpv_gpu_next.h"
static void *proc(void *ctx,const char *name) { return dlsym(RTLD_DEFAULT,name); }
struct notification { pthread_mutex_t lock; pthread_cond_t condition; int pending; };
static void notify(void *opaque) {
    struct notification *n=opaque;
    pthread_mutex_lock(&n->lock);n->pending=1;pthread_cond_signal(&n->condition);pthread_mutex_unlock(&n->lock);
}
static void wait_notification(struct notification *n) {
    struct timespec deadline;clock_gettime(CLOCK_REALTIME,&deadline);
    deadline.tv_nsec+=20000000;
    if(deadline.tv_nsec>=1000000000) {deadline.tv_sec++;deadline.tv_nsec-=1000000000;}
    pthread_mutex_lock(&n->lock);
    if(!n->pending)pthread_cond_timedwait(&n->condition,&n->lock,&deadline);
    n->pending=0;pthread_mutex_unlock(&n->lock);
}
static size_t heap_bytes(void) {
    malloc_statistics_t s={0};malloc_zone_statistics(NULL,&s);return s.size_in_use;
}
int main(int argc,char **argv) {
    const char *expected=getenv("PPX_EXPECTED_MPV_IMAGE");
    char expected_path[PATH_MAX],loaded_path[PATH_MAX];
    Dl_info image={0};
    if(!expected || !realpath(expected,expected_path)) return 6;
    void *symbols[]={(void *)mpv_create,(void *)mpv_render_context_create};
    for(unsigned n=0;n<sizeof(symbols)/sizeof(symbols[0]);n++) {
        if(!dladdr(symbols[n],&image) || !realpath(image.dli_fname,loaded_path)
           || strcmp(expected_path,loaded_path)) {
            fprintf(stderr,"MPV IMAGE MISMATCH expected=%s actual=%s\n",expected_path,image.dli_fname?image.dli_fname:"unknown");
            return 6;
        }
        fprintf(stderr,"MPV IMAGE VERIFIED %s\n",loaded_path);
    }
    int width=argc>2?atoi(argv[2]):64, height=argc>3?atoi(argv[3]):64;
    assert(width>=64 && width<=7680 && height>=64 && height<=4320);
    fprintf(stderr,"HOST TARGET %dx%d; center 64x64 pixel sample\n",width,height);
    CGLPixelFormatAttribute attributes[]={kCGLPFAOpenGLProfile,
       (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,kCGLPFAAccelerated,0};
    CGLPixelFormatObj format=NULL;CGLContextObj gl=NULL;GLint count=0;
    assert(CGLChoosePixelFormat(attributes,&format,&count)==kCGLNoError && count);
    assert(CGLCreateContext(format,NULL,&gl)==kCGLNoError);
    CGLDestroyPixelFormat(format);assert(CGLSetCurrentContext(gl)==kCGLNoError);
    GLuint texture=0,fbo=0;glGenTextures(1,&texture);glBindTexture(GL_TEXTURE_2D,texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA16F,width,height,0,GL_RGBA,GL_FLOAT,NULL);
    glGenFramebuffers(1,&fbo);glBindFramebuffer(GL_FRAMEBUFFER,fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,texture,0);
    glDrawBuffer(GL_COLOR_ATTACHMENT0);
    assert(glCheckFramebufferStatus(GL_FRAMEBUFFER)==GL_FRAMEBUFFER_COMPLETE);
    assert(glGetError()==GL_NO_ERROR);
    struct notification notification={PTHREAD_MUTEX_INITIALIZER,PTHREAD_COND_INITIALIZER,0};
    mpv_handle *mpv=mpv_create();assert(mpv);
    mpv_set_wakeup_callback(mpv,notify,&notification);
    assert(mpv_set_option_string(mpv,"vo","libmpv")==0);
    assert(mpv_set_option_string(mpv,"audio","no")==0);
    assert(mpv_set_option_string(mpv,"hwdec","auto-safe")==0);
    const char *tone_mapping=getenv("PPX_TONE_MAPPING");
    if(tone_mapping) {
        assert(mpv_set_option_string(mpv,"tone-mapping",tone_mapping)==0);
        fprintf(stderr,"TONE_MAPPING_POLICY %s\n",tone_mapping);
    }
    assert(mpv_set_option_string(mpv,"terminal","no")==0);
    assert(mpv_request_log_messages(mpv,"warn")==0);
    assert(mpv_initialize(mpv)==0);
    mpv_opengl_init_params init={.get_proc_address=proc};int advanced=1;
    mpv_render_param create[]={{MPV_RENDER_PARAM_API_TYPE,MP_GPU_NEXT_API_TYPE},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL,&advanced},{0}};
    mpv_render_context *render=NULL;
    int err=mpv_render_context_create(&render,mpv,create);
    if(err<0) { fprintf(stderr,"backend create: %s\n",mpv_error_string(err));return 2; }
    mpv_render_context_set_update_callback(render,notify,&notification);
    if(argc>1) { const char *load[]={"loadfile",argv[1],NULL};assert(mpv_command_async(mpv,99,load)==0); }
    struct mp_gpu_next_target_contract target={.version=MP_GPU_NEXT_TARGET_VERSION,
        .size=sizeof(target),.primaries=MP_NEXT_PRIM_BT2020,.transfer=MP_NEXT_TRC_LINEAR,
        .range=MP_NEXT_RANGE_FULL,.width=width,.height=height,.internal_format=GL_RGBA16F,
        .component_depth=16,.reference_white_nits=203,.peak_nits=400,.black_nits=.01f};
    // Illustrative explicit host facts, not discovered EDR/headroom. A real
    // bridge must derive display peak and map 203 nits to its consumer scale.
    mpv_opengl_fbo output={.fbo=(int)fbo,.w=width,.h=height,.internal_format=GL_RGBA16F};
    int block=1;
    struct mp_gpu_next_render_diagnostics diagnostics={
        .version=MP_GPU_NEXT_TARGET_VERSION,.size=sizeof(diagnostics)};
    unsigned diagnostic_failures=0;
    double render_us=0,finish_us=0,readback_us=0; unsigned rendered=0;
    unsigned late=0; double lateness_us=0; unsigned perf_replies=0;
    mpv_render_param draw[]={{MPV_RENDER_PARAM_OPENGL_FBO,&output},
        {MP_GPU_NEXT_RENDER_PARAM_TARGET,&target},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},
        {MP_GPU_NEXT_RENDER_PARAM_DIAGNOSTICS,&diagnostics},{0}};
    size_t warm=0,mid=0,end=0;
    float pixels[64*64*4]; double prior_sum=0; int samples=0,changed=0,nonfinite=0,logged_errors=0; double first_pts=-1,last_pts=-1;
    int shutdown=0;
    int64_t started=mpv_get_time_us(mpv);
    for(int i=0;i<1500 && mpv_get_time_us(mpv)-started<90000000;i++) {
        if(argc>1) {
            for(;;) {
            mpv_event *event=mpv_wait_event(mpv,0);
            if(event->event_id==MPV_EVENT_NONE)break;
            if(event->event_id==MPV_EVENT_SHUTDOWN) { shutdown=1;break; }
            if(event->event_id==MPV_EVENT_GET_PROPERTY_REPLY) {
                mpv_event_property *property=event->data;
                fprintf(stderr,"ASYNC_PROPERTY id=%llu error=%d name=%s\n",(unsigned long long)event->reply_userdata,event->error,property->name);
                if(event->error==0 && property->format==MPV_FORMAT_STRING && property->data) {
                    fprintf(stderr,"PROPERTY_VALUE %s: %s\n",property->name,*(char **)property->data);
                    if(!strcmp(property->name,"vo-passes"))perf_replies++;
                    if(!strcmp(property->name,"time-pos")) {
                        double pts=atof(*(char **)property->data);
                        if(first_pts<0)first_pts=pts;last_pts=pts;
                    }
                }
            }
            if(event->event_id==MPV_EVENT_LOG_MESSAGE) {
                const mpv_event_log_message *msg=event->data;
                fprintf(stderr,"MPVLOG [%s] %s: %s",msg->prefix,msg->level,msg->text);
                if(msg->log_level<=MPV_LOG_LEVEL_ERROR)logged_errors++;
            }
            }
            if(shutdown)break;
            uint64_t updates=mpv_render_context_update(render);
            if(!(updates & MPV_RENDER_UPDATE_FRAME)) { wait_notification(&notification);i--; continue; }
        }
        if(i%50==0) {
            const char *properties[]={"vo-passes","decoder-frame-drop-count","frame-drop-count","vo-delayed-frame-count","mistimed-frame-count","time-pos","hwdec-current"};
            for(unsigned p=0;p<sizeof(properties)/sizeof(properties[0]);p++)
                assert(mpv_get_property_async(mpv,p+1,properties[p],MPV_FORMAT_STRING)==0);
        }
        mpv_render_frame_info frame_info={0};
        mpv_render_param information={MPV_RENDER_PARAM_NEXT_FRAME_INFO,&frame_info};
        assert(mpv_render_context_get_info(render,information)==0);
        frame_info.target_time/=1000; // pinned vo_libmpv.c exports vo_frame.pts (ns)
        int64_t render_begin=mpv_get_time_us(mpv);
        err=mpv_render_context_render(render,draw);
        int64_t render_done=mpv_get_time_us(mpv);
        render_us+=render_done-render_begin;rendered++;
        if(frame_info.target_time && render_done>frame_info.target_time) {
            late++;lateness_us+=render_done-frame_info.target_time;
        }
        if(i%50==0)fprintf(stderr,"FRAME_TIMING index=%d flags=%llu target=%lld begin=%lld done=%lld late_us=%lld\n",i,(unsigned long long)frame_info.flags,(long long)frame_info.target_time,(long long)render_begin,(long long)render_done,(long long)(frame_info.target_time?render_done-frame_info.target_time:0));
        if(diagnostics.render_error_bits || diagnostics.disabled_hook_count || diagnostics.hwdec_import_failed)diagnostic_failures++;
        if(i%50==0 || err<0)fprintf(stderr,"DIAGNOSTICS iteration=%d acquired=%u valid=%u errors=%u hooks=%u import_failed=%u\n",i,diagnostics.target_acquired,diagnostics.content_valid,diagnostics.render_error_bits,diagnostics.disabled_hook_count,diagnostics.hwdec_import_failed);
        if(err<0) { fprintf(stderr,"render %d: %s\n",i,mpv_error_string(err));return 3; }
        glFinish();int64_t gpu_finished=mpv_get_time_us(mpv);finish_us+=gpu_finished-render_done;
        if(i%50==0)fprintf(stderr,"GPU_COMPLETION index=%d offset_us=%lld\n",i,(long long)(frame_info.target_time?gpu_finished-frame_info.target_time:0));mpv_render_context_report_swap(render);assert(glIsTexture(texture) && glIsFramebuffer(fbo));
        if(argc>1 && i%50==0) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER,fbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            int64_t read_begin=mpv_get_time_us(mpv);
            glReadPixels((width-64)/2,(height-64)/2,64,64,GL_RGBA,GL_FLOAT,pixels);
            readback_us+=mpv_get_time_us(mpv)-read_begin;
            assert(glGetError()==GL_NO_ERROR);
            double sum=0; float peak=0;
            for(int n=0;n<64*64;n++) for(int c=0;c<3;c++) {
                float v=pixels[4*n+c];
                if(!isfinite(v))nonfinite++; else {sum+=v;if(v>peak)peak=v;}
            }
            if(samples && fabs(sum-prior_sum)>.01)changed++;
            samples++;prior_sum=sum;
            fprintf(stderr,"READBACK iteration=%d rgb_sum=%.9g peak=%.9g finite_errors=%d\n",i,sum,peak,nonfinite);
        }
        if(i==499)warm=heap_bytes();if(i==999)mid=heap_bytes();if(i==1499)end=heap_bytes();
    }
    fprintf(stderr,"ASYNC_PERF_SUMMARY replies=%u positive_render_completion_offset_count=%u mean_positive_offset_us=%.3f\n",perf_replies,late,late?lateness_us/late:0);
    fprintf(stderr,"HOST TIMING frames=%u render_including_target_wait_us=%.3f finish_us=%.3f readback_total_us=%.3f\n",rendered,rendered?render_us/rendered:0,rendered?finish_us/rendered:0,readback_us);
    fprintf(stderr,"READBACK SUMMARY samples=%d changed=%d finite_errors=%d\n",samples,changed,nonfinite);
    target.width=width+1;
    assert(mpv_render_context_render(render,draw)==MPV_ERROR_INVALID_PARAMETER);
    target.width=width;
    mpv_render_context_set_update_callback(render,NULL,NULL);
    mpv_set_wakeup_callback(mpv,NULL,NULL);
    mpv_render_context_free(render);
    assert(glIsTexture(texture) && glIsFramebuffer(fbo));
    fprintf(stderr,"host objects retained; process allocator sample %zu/%zu/%zu bytes (not a leak verdict)\n",warm,mid,end);
    mpv_terminate_destroy(mpv);
    glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&texture);
    CGLSetCurrentContext(NULL);CGLDestroyContext(gl);
    pthread_cond_destroy(&notification.condition);pthread_mutex_destroy(&notification.lock);
    if(argc>1 && (shutdown || rendered!=1500 || !perf_replies || !samples || !changed || nonfinite || logged_errors || diagnostic_failures || first_pts<0 || last_pts<=first_pts)) {
        fprintf(stderr,"CONTENT GATE FAILED samples=%d changed=%d nonfinite=%d logged_errors=%d\n",samples,changed,nonfinite,logged_errors);return 4;
    }
    puts("TRANSPORT PASS ONLY: CGL calls/host ownership; readback/logs require independent content acceptance");
    return 0;
}
