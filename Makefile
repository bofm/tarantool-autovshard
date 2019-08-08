DOCKER_IMAGE=tnt-autovshard

.PHONY: docker clean test test-ci run kill run-bash docker-image-name

.docker: $(shell find autovshard scripts tests Dockerfile docker-compose.yaml *.rockspec .dockerignore -print)
	docker build --pull -t "$(DOCKER_IMAGE)" .
	docker-compose build --pull
	@echo "$(DOCKER_IMAGE)" > .docker

docker: .docker

build: docker
	docker-compose build --pull

clean:
	docker-compose kill
	docker-compose rm -fv
	docker rmi "$(DOCKER_IMAGE)"
	rm -f ./.docker
	rm -f ./output/*

test:
	docker-compose run --rm a1 ./scripts/test.sh --verbose

test-coverage:
	docker-compose run --rm a1 ./scripts/test.sh --verbose --coverage

test-ci: build test-coverage

coverage-ci:
	docker-compose run --rm \
		-e TRAVIS=true \
		-e CI=true \
		-e COVERALLS_REPO_TOKEN=${COVERALLS_REPO_TOKEN} \
		-e TRAVIS_JOB_ID=${TRAVIS_JOB_ID} \
		-e TRAVIS_BRANCH=${TRAVIS_BRANCH} \
		-e TRAVIS_REPO_SLUG=${TRAVIS_REPO_SLUG} \
		a1 \
		sh -c "cd output && exec luacov-coveralls -v --root=/usr/share/tarantool/"

run:
	docker-compose run --rm a1 tarantool

kill:
	docker-compose kill

run-bash: build
	docker-compose run --rm a1 bash

docker-image-name:
	@echo $(DOCKER_IMAGE)
