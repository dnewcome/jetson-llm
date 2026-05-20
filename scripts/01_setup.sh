#!/bin/bash
# Run once on the Jetson to install deps and build llama.cpp with CUDA
# All work goes under /data/george/ to avoid interfering with other users

set -e

BASE=/data/george
LLAMA_DIR=$BASE/llama.cpp

echo "=== Creating directory structure ==="
mkdir -p $BASE/models $BASE/benchmark-results $LLAMA_DIR

echo "=== Installing build dependencies ==="
sudo apt-get update -qq
sudo apt-get install -y build-essential libcurl4-openssl-dev python3-pip

echo "=== Installing newer cmake (llama.cpp requires >= 3.21) ==="
pip3 install --upgrade cmake --quiet
export PATH="$HOME/.local/bin:$PATH"
cmake --version

echo "=== Cloning llama.cpp ==="
if [ ! -d $LLAMA_DIR/.git ]; then
    git clone --depth=1 https://github.com/ggerganov/llama.cpp.git $LLAMA_DIR
else
    cd $LLAMA_DIR && git pull
fi

echo "=== Building llama.cpp with CUDA (Xavier Volta = compute 7.2) ==="
cd $LLAMA_DIR
mkdir -p build && cd build
cmake .. \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES=72 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_TESTS=OFF \
    2>&1 | tail -10

make -j$(nproc) llama-bench llama-cli llama-server 2>&1 | tail -20

echo ""
echo "=== Build complete ==="
ls -lh $LLAMA_DIR/build/bin/
echo ""
echo "export PATH=$LLAMA_DIR/build/bin:\$PATH"
