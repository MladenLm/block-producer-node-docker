FROM ubuntu:rolling AS builder
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update -y && \
    apt-get install automake build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev make g++ tmux git jq wget libncursesw5 libtool autoconf liblmdb-dev curl -y

# Create src folder for installations
RUN mkdir src

# Install libsodium
RUN cd src && \
    git clone https://github.com/input-output-hk/libsodium && \
    cd libsodium && \
    git checkout 66f017f1 && \
    ./autogen.sh && \
    ./configure && \
    make && \
    make install

#Install libsecp256k1
RUN cd src && \
    git clone https://github.com/bitcoin-core/secp256k1 && \
    cd secp256k1 && \
    git checkout ac83be33 && \
    ./autogen.sh && \
    ./configure --enable-module-schnorrsig --enable-experimental && \
    make && \
    make install

# Install GHC version 8.10.4 and Cabal
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | BOOTSTRAP_HASKELL_NONINTERACTIVE=1 BOOTSTRAP_HASKELL_MINIMAL=1 sh
ENV PATH="/root/.ghcup/bin:${PATH}"
RUN ghcup upgrade && \
    ghcup install cabal 3.6.2.0 && \
    ghcup set cabal 3.6.2.0 && \
    ghcup install ghc 8.10.7 && \
    ghcup set ghc 8.10.7

# Update PATH
ENV LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
ENV PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"

# Update Cabal
RUN cabal update

# Clone Cardano Node and checkout to latest version
RUN TAG=$(curl -s https://api.github.com/repos/input-output-hk/cardano-node/releases/latest | jq -r .tag_name) && \
    echo $TAG && \
    cd src && \
    git clone https://github.com/input-output-hk/cardano-node.git && \
    cd cardano-node && \
    git fetch --all --recurse-submodules --tags && \
    git tag && \
    git checkout tags/${TAG}

# Set config for cabal project
RUN echo "package cardano-crypto-praos" >>  /src/cardano-node/cabal.project.local && \
    echo "flags: -external-libsodium-vrf" >>  /src/cardano-node/cabal.project.local

# Build cardano-node & cardano-cli
RUN cd src/cardano-node && \
    cabal build all

# Find and copy binaries to ~/.local/bin
RUN cp $(find /src/cardano-node/dist-newstyle/build -type f -name "cardano-cli") /usr/local/bin/cardano-cli
RUN cp $(find /src/cardano-node/dist-newstyle/build -type f -name "cardano-node") /usr/local/bin/cardano-node

FROM ubuntu:rolling

COPY --from=builder /usr/local/bin/cardano-cli /usr/local/bin
COPY --from=builder /usr/local/bin/cardano-node /usr/local/bin

# Install Cardano dependencies
RUN apt-get update -y && \
    apt-get install automake build-essential pkg-config libffi-dev libgmp-dev libssl-dev libtinfo-dev libsystemd-dev zlib1g-dev make g++ tmux git jq wget libncursesw5 libtool autoconf liblmdb-dev curl vim -y

#Install libsodium
RUN mkdir src && \
    cd src && \
    git clone https://github.com/input-output-hk/libsodium && \
    cd libsodium && \
    git checkout 66f017f1 && \
    ./autogen.sh && \
    ./configure && \
    make && \
    make install

#Install libsecp256k1
RUN cd src && \
    git clone https://github.com/bitcoin-core/secp256k1 && \
    cd secp256k1 && \
    git checkout ac83be33 && \
    ./autogen.sh && \
    ./configure --enable-module-schnorrsig --enable-experimental && \
    make && \
    make install

# Delete src folder
RUN rm -r /src

RUN mkdir -P /node/configuration

# Get latest config files from https://book.world.dev.cardano.org/environments.html
RUN curl -s -o /node/configuration/config.json https://book.world.dev.cardano.org/environments/mainnet/config.json \
    curl -s -o /node/configuration/byron-genesis.json https://book.world.dev.cardano.org/environments/mainnet/byron-genesis.json \
    curl -s -o /node/configuration/shelley-genesis.json https://book.world.dev.cardano.org/environments/mainnet/shelley-genesis.json \
    curl -s -o /node/configuration/alonzo-genesis.json https://book.world.dev.cardano.org/environments/mainnet/alonzo-genesis.json

# Change config to save them in /node/log/node.log file instead of stdout
RUN sed -i 's/StdoutSK/FileSK/' /node/configuration/config.json && \
    sed -i 's/stdout/\/node\/logs\/node.log/' /node/configuration/config.json && \
    sed -i 's/\"TraceBlockFetchDecisions\": false/\"TraceBlockFetchDecisions\": true/' /node/configuration/config.json && \
    sed -i 's/\"127.0.0.1\"/\"0.0.0.0\"/' /node/configuration/config.json

ARG RELAY_IP
ARG REPLAY_PORT

RUN echo '{\n\
  "Producers": [\n\
    {\n\
      "addr": "${RELAY_IP}", #Relay IP Address\n\
      "port": ${REPLAY_PORT},\n\
      "valency": 1\n\
    }\n\
  ]\n\
}'\
>> /node/topology.json

# Update libsodium PATH
ENV LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
ENV PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH"

# Set node socket evironment for cardano-cli
ENV CARDANO_NODE_SOCKET_PATH="/node/ipc/node.socket"

# Set mainnet magic number
ENV MAGIC_NUMBER=764824073

# Create keys, ipc, data, scripts, logs folders
RUN mkdir -p /node/ipc /node/logs /node/pool-keys

# Copy scripts
COPY cardano-scripts/ /usr/local/bin

# Set executable permits
RUN /bin/bash -c "chmod +x /usr/local/bin/*.sh"

# Run cardano-node at the startup
CMD [ "/usr/local/bin/run-cardano-node.sh" ]