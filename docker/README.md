# Running Omniscape in Docker

## Build the image

```bash
docker build . \
  -f docker/Dockerfile \
  -t achubaty/omniscape:latest
```

## Launch a container

```bash
docker run -it --rm \
  -v $(pwd):/home/omniscape \
  -w /home/omniscape \
  -e JULIA_NUM_THREADS=64 \
  --cpus=64 \
  --memory=400g \
  achubaty/omniscape:latest
```
