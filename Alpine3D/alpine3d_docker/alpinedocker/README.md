# Alpine3D Docker build

This image builds MeteoIO, Snowpack, and Alpine3D from source in this order:
1. MeteoIO
2. Snowpack
3. Alpine3D

## Build

```bash
docker build -t alpine3d:local .
```
## Run a simulation

```bash
docker run --rm -it   --user $(id -u):$(id -g)   -v "$PWD/data:/data"   -v "$PWD:/work"   -w /work   alpine3d   run.sh
```

