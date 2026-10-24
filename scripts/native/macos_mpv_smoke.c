#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv) {
 if(argc < 2) return 2;
 void *lib=dlopen(argv[1],RTLD_NOW | RTLD_LOCAL);
 if(!lib){fprintf(stderr,"DLOPEN_NOW_FAIL: %s\n",dlerror());return 10;}
 puts("DLOPEN_NOW_PASS");
 void *(*create)(void)=dlsym(lib,"mpv_create");
 int (*opt)(void*,const char*,const char*)=dlsym(lib,"mpv_set_option_string");
 int (*init)(void*)=dlsym(lib,"mpv_initialize");
 void (*destroy)(void*)=dlsym(lib,"mpv_terminate_destroy");
 if(!create||!opt||!init||!destroy){puts("API_MISSING");return 11;}
 void *mpv=create();if(!mpv){puts("CREATE_FAIL");return 12;}
 const char *opts[][2]={{"config","no"},{"vo","null"},{"ao","null"},{"idle","yes"},{"terminal","no"}};
 for(int i=0;i<5;i++){int r=opt(mpv,opts[i][0],opts[i][1]);if(r<0){fprintf(stderr,"OPTION_FAIL %s %d\n",opts[i][0],r);destroy(mpv);return 13;}}
 int r=init(mpv); printf("INITIALIZE_RESULT %d\n",r);destroy(mpv);dlclose(lib);return r<0?14:0;
}
