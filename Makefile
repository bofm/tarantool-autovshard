DOCKER_IMAGE=tnt-autovshard

.PHONY: docker clean test test-ci run kill run-bash docker-image-name

.docker: $(shell find autovshard scripts tests/*.lua Dockerfile *.rockspec .dockerignore -print)
	docker build --pull -t "$(DOCKER_IMAGE)" .
	docker pull consul:1.5.3
	@echo "$(DOCKER_IMAGE)" > .docker

.docker-compose: docker-compose.yaml
	docker-compose build --pull
	date > .docker-compose

docker-compose: .docker-compose

docker: .docker

build: docker

clean:
	docker-compose kill
	docker-compose rm -fv
	docker rmi "$(DOCKER_IMAGE)" || :
	rm -rf \
		./.docker \
		./output/* \
		./.pipenv \
		./tmp

test: docker-compose
	docker-compose run --rm a1 ./scripts/test.sh --verbose

.pipenv: Pipfile.lock Pipfile
	which pipenv || python -m pip install pipenv
	pipenv install --dev --deploy
	date > .pipenv

test-e2e-ci: .pipenv docker
	pipenv run pytest -s

test-coverage: docker-compose
	docker-compose run --rm a1 ./scripts/test.sh --verbose --coverage

test-ci: build test-coverage

coverage-ci: docker-compose
	docker-compose run --rm \
		-e TRAVIS=true \
		-e CI=true \
		-e COVERALLS_REPO_TOKEN=${COVERALLS_REPO_TOKEN} \
		-e TRAVIS_JOB_ID=${TRAVIS_JOB_ID} \
		-e TRAVIS_BRANCH=${TRAVIS_BRANCH} \
		-e TRAVIS_REPO_SLUG=${TRAVIS_REPO_SLUG} \
		a1 \
		sh -c "cd output && exec luacov-coveralls -v --root=/usr/share/tarantool/"

run: docker-compose
	docker-compose run --rm a1 tarantool

kill:
	docker-compose kill

run-bash: docker-compose
	docker-compose run --rm a1 bash

docker-image-name:
	@echo $(DOCKER_IMAGE)
