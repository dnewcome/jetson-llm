#include <cuda_runtime.h>
#include <stdio.h>
int main(){
  size_t f=0,t=0; cudaMemGetInfo(&f,&t);
  printf("cudaMemGetInfo: free=%.2f GB total=%.2f GB\n", f/1e9, t/1e9);
  // largest SINGLE contiguous block:
  for(size_t gb=28; gb>=1; gb--){
    void* p;
    if(cudaMalloc(&p, gb*1000000000ULL)==cudaSuccess){
      printf("largest single block: %zu GB\n", gb);
      cudaFree(p);
      break;
    }
  }
  // cumulative via 512MB chunks (how llama.cpp actually allocates):
  size_t c=512ULL<<20, got=0; void* p;
  while(cudaMalloc(&p,c)==cudaSuccess) got+=c;
  printf("cumulative many-chunk: %.2f GB before failure\n", got/1e9);
  return 0;
}
