// Allocator-bound churn: tight alloc/free with minimal harness work.
// Mode A: pure LIFO reuse (alloc then immediately free) -> tests fast-path cycles.
// Mode B: windowed churn (keep N live, free oldest) -> tests temporal reuse / L1.
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <cstdio>
int main(int argc, char** argv){
  int mode = argc>1? atoi(argv[1]) : 1;     // 1=pure, 2=windowed
  long iters = argc>2? atol(argv[2]) : 200000000L;
  size_t win = argc>3? atol(argv[3]) : 4096; // live objects in windowed mode
  size_t sz  = argc>4? atol(argv[4]) : 32;
  volatile uint64_t sink=0;
  if(mode==1){
    for(long i=0;i<iters;i++){
      char* p=(char*)malloc(sz);
      p[0]=(char)i; p[sz-1]=(char)i;        // touch block (realistic)
      sink+=p[0];
      free(p);
    }
  } else {
    std::vector<char*> live(win,nullptr);
    for(long i=0;i<iters;i++){
      size_t idx=i%win;
      if(live[idx]){ sink+=live[idx][0]; free(live[idx]); }
      char* p=(char*)malloc(sz);
      p[0]=(char)i; p[sz-1]=(char)i;
      live[idx]=p;
    }
    for(auto p:live) if(p) free(p);
  }
  fprintf(stderr,"sink=%llu\n",(unsigned long long)sink);
  return 0;
}
