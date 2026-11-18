# Shared by the sync benchmark scripts.
REPO=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
# The image CI's Linux job uses (Dockerfile.linux: swift:6.1-jammy plus SQLite).
IMAGE=lattice-linux
image() {
  docker image inspect $IMAGE > /dev/null 2>&1 || docker build -q -t $IMAGE - < "$REPO/Dockerfile.linux" > /dev/null
}
