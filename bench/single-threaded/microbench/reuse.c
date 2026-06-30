#include <stdio.h>
#include <stdlib.h>
int main(){
  for(int i=0;i<5;i++){
    void* a=malloc(32); free(a);
    void* b=malloc(32); free(b);
    printf("a=%p b=%p same=%d\n",a,b,a==b);
  }
  // sequence: alloc two, free both, realloc two
  void* x=malloc(32); void* y=malloc(32);
  printf("x=%p y=%p\n",x,y); free(x); free(y);
  void* z=malloc(32); void* w=malloc(32);
  printf("z=%p w=%p  z==y?%d z==x?%d\n",z,w,z==y,z==x);
  return 0;
}
