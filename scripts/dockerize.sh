#!/bin/bash
TAG=''
VERSION_TAG=

case "$TRAVIS_BRANCH" in
  "master")
    TAG=latest
    VERSION_TAG=$TRAVIS_BUILD_NUMBER
    ;;
  "develop")
    TAG=dev
    VERSION_TAG=$TAG-$TRAVIS_BUILD_NUMBER
    ;;
esac

# Branches other than master and develop are built and tested but produce no
# image. Without this guard an untagged branch would run `docker build -t repo:`
# and push a malformed tag.
if [ -z "$TAG" ]; then
  echo "No image tag is defined for branch '$TRAVIS_BRANCH' — skipping the image build and push."
  exit 0
fi

REPOSITORY=$DOCKER_USERNAME/pacco.apigateway

docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD
docker build -t $REPOSITORY:$TAG -t $REPOSITORY:$VERSION_TAG .
docker push $REPOSITORY:$TAG
docker push $REPOSITORY:$VERSION_TAG
