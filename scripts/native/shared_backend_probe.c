/* No-window capability probe. Final-bundle backend and optional local-content probe.
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
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <malloc/malloc.h>
#include "mpv/client.h"
#include "mpv/render_gl.h"
#include "video/out/gpu_next/libmpv_gpu_next.h"
static void *proc(void *ctx,const char *name) { return dlsym(RTLD_DEFAULT,name); }
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
    mpv_handle *mpv=mpv_create();assert(mpv);
    assert(mpv_set_option_string(mpv,"vo","libmpv")==0);
    assert(mpv_set_option_string(mpv,"audio","no")==0);
    assert(mpv_set_option_string(mpv,"hwdec","auto-safe")==0);
    assert(mpv_set_option_string(mpv,"terminal","yes")==0);
    assert(mpv_request_log_messages(mpv,"warn")==0);
    assert(mpv_initialize(mpv)==0);
    mpv_opengl_init_params init={.get_proc_address=proc};int advanced=1;
    mpv_render_param create[]={{MPV_RENDER_PARAM_API_TYPE,MP_GPU_NEXT_API_TYPE},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,&init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL,&advanced},{0}};
    mpv_render_context *render=NULL;
    int err=mpv_render_context_create(&render,mpv,create);
    if(err<0) { fprintf(stderr,"backend create: %s\n",mpv_error_string(err));return 2; }
    if(argc>1) { const char *load[]={"loadfile",argv[1],NULL};assert(mpv_command(mpv,load)==0); }
    struct mp_gpu_next_target_contract target={.version=MP_GPU_NEXT_TARGET_VERSION,
        .size=sizeof(target),.primaries=MP_NEXT_PRIM_BT2020,.transfer=MP_NEXT_TRC_LINEAR,
        .range=MP_NEXT_RANGE_FULL,.width=width,.height=height,.internal_format=GL_RGBA16F,
        .component_depth=16,.reference_white_nits=203,.peak_nits=400,.black_nits=.01f};
    // Illustrative explicit host facts, not discovered EDR/headroom. A real
    // bridge must derive display peak and map 203 nits to its consumer scale.
    mpv_opengl_fbo output={.fbo=(int)fbo,.w=width,.h=height,.internal_format=GL_RGBA16F};
    int block=0;
    struct mp_gpu_next_render_diagnostics diagnostics={
        .version=MP_GPU_NEXT_TARGET_VERSION,.size=sizeof(diagnostics)};
    unsigned diagnostic_failures=0;
    mpv_render_param draw[]={{MPV_RENDER_PARAM_OPENGL_FBO,&output},
        {MP_GPU_NEXT_RENDER_PARAM_TARGET,&target},
        {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME,&block},
        {MP_GPU_NEXT_RENDER_PARAM_DIAGNOSTICS,&diagnostics},{0}};
    size_t warm=0,mid=0,end=0;
    float pixels[64*64*4]; double prior_sum=0; int samples=0,changed=0,nonfinite=0,logged_errors=0; double first_pts=-1,last_pts=-1;
    for(int i=0;i<(argc>1?1500:3);i++) {
        if(argc>1) {
            mpv_event *event=mpv_wait_event(mpv,.005);
            if(event->event_id==MPV_EVENT_SHUTDOWN) break;
            if(event->event_id==MPV_EVENT_LOG_MESSAGE) {
                const mpv_event_log_message *msg=event->data;
                fprintf(stderr,"MPVLOG [%s] %s: %s",msg->prefix,msg->level,msg->text);
                if(msg->log_level<=MPV_LOG_LEVEL_ERROR)logged_errors++;
            }
            mpv_render_context_update(render);
        }
        err=mpv_render_context_render(render,draw);
        if(diagnostics.render_error_bits || diagnostics.disabled_hook_count || diagnostics.hwdec_import_failed || diagnostics.target_acquired!=1 || diagnostics.content_valid!=1)diagnostic_failures++;
        if(i%50==0 || err<0)fprintf(stderr,"DIAGNOSTICS iteration=%d acquired=%u valid=%u errors=%u hooks=%u import_failed=%u\n",i,diagnostics.target_acquired,diagnostics.content_valid,diagnostics.render_error_bits,diagnostics.disabled_hook_count,diagnostics.hwdec_import_failed);
        if(err<0) { fprintf(stderr,"render %d: %s\n",i,mpv_error_string(err));return 3; }
        glFinish();assert(glIsTexture(texture) && glIsFramebuffer(fbo));
        if(argc>1 && i%50==0) {
            glBindFramebuffer(GL_READ_FRAMEBUFFER,fbo);
            glReadBuffer(GL_COLOR_ATTACHMENT0);
            glReadPixels((width-64)/2,(height-64)/2,64,64,GL_RGBA,GL_FLOAT,pixels);
            assert(glGetError()==GL_NO_ERROR);
            double sum=0; float peak=0;
            for(int n=0;n<64*64;n++) for(int c=0;c<3;c++) {
                float v=pixels[4*n+c];
                if(!isfinite(v))nonfinite++; else {sum+=v;if(v>peak)peak=v;}
            }
            if(samples && fabs(sum-prior_sum)>.01)changed++;
            samples++;prior_sum=sum;
            double pts=-1;
            if(mpv_get_property(mpv,"time-pos",MPV_FORMAT_DOUBLE,&pts)==0) {
                if(first_pts<0)first_pts=pts;last_pts=pts;
            }
            char *hw=mpv_get_property_string(mpv,"hwdec-current");
            fprintf(stderr,"SOURCE iteration=%d pts=%.9g hwdec=%s\n",i,pts,hw?hw:"unknown");
            mpv_free(hw);
            fprintf(stderr,"READBACK iteration=%d rgb_sum=%.9g peak=%.9g finite_errors=%d\n",i,sum,peak,nonfinite);
        }
        if(i==499)warm=heap_bytes();if(i==999)mid=heap_bytes();if(i==1499)end=heap_bytes();
    }
    fprintf(stderr,"READBACK SUMMARY samples=%d changed=%d finite_errors=%d\n",samples,changed,nonfinite);
    target.width=width+1;
    assert(mpv_render_context_render(render,draw)==MPV_ERROR_INVALID_PARAMETER);
    target.width=width;
    mpv_render_context_free(render);
    assert(glIsTexture(texture) && glIsFramebuffer(fbo));
    fprintf(stderr,"host objects retained; process allocator sample %zu/%zu/%zu bytes (not a leak verdict)\n",warm,mid,end);
    mpv_terminate_destroy(mpv);
    glDeleteFramebuffers(1,&fbo);glDeleteTextures(1,&texture);
    CGLSetCurrentContext(NULL);CGLDestroyContext(gl);
    if(diagnostic_failures) return 5;
    if(argc>1 && (!samples || !changed || nonfinite || logged_errors || diagnostic_failures || first_pts<0 || last_pts<=first_pts)) {
        fprintf(stderr,"CONTENT GATE FAILED samples=%d changed=%d nonfinite=%d logged_errors=%d\n",samples,changed,nonfinite,logged_errors);return 4;
    }
    puts("TRANSPORT PASS ONLY: CGL calls/host ownership; readback/logs require independent content acceptance");
    return 0;
}
