DOCKER_IMAGE=tnt-autovshard

.PHONY: docker clean test test-ci run kill run-bash docker-image-name

.docker: $(shell find autovshard scripts tests Dockerfile docker-compose.yaml *.rockspec .dockerignore -print)
	docker build --pull -t "$(DOCKER_IMAGE)" .
	docker-compose build --pull
	@echo "$(DOCKER_IMAGE)" > .docker

docker: .docker

build: docker
	docker-compose build

clean:
	docker-compose kill
	docker-compose rm -fv
	docker rmi "$(DOCKER_IMAGE)"
	rm -f ./.docker

test:
	docker-compose run --rm a1 ./scripts/test.sh

test-ci: build
	docker-compose run --rm a1 ./scripts/test.sh

run:
	docker-compose run --rm a1 tarantool

kill:
	docker-compose kill

run-bash: build
	docker-compose run --rm a1 bash

docker-image-name:
	@echo $(DOCKER_IMAGE)
