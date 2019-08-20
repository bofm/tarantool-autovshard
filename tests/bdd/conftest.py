import itertools
import logging
from os import getenv
from random import randint

import docker as docker
import pytest
from docker.errors import APIError, NotFound
from funcy import ignore, retry

from .util import get_port_on_host, wait_tcp_port

counter = itertools.count()


@pytest.fixture
def run_id():
    return f"{next(counter):03d}"


@pytest.fixture(scope="session")
def docker_client():
    if getenv("TRAVIS") == "true":
        return docker.DockerClient(
            base_url="unix://var/run/docker.sock", version="1.38",
        )
    return docker.from_env()


@pytest.fixture(scope="module")
def docker_network(docker_client):
    network_name = f"test_network_{randint(1, 99999)}"

    @ignore(NotFound)
    @retry(3, APIError, 0.2)
    def cleanup():
        for c in docker_client.containers.list(all=True):
            if c.attrs.get("HostConfig", {}).get("NetworkMode") == network_name:
                c.remove(force=True, v=True)
        for n in docker_client.networks.list():
            if n.name == network_name:
                n.remove()

    cleanup()
    network = docker_client.networks.create(network_name)
    yield network.name
    cleanup()


@pytest.fixture(autouse=True)
def setup_logging(caplog):
    caplog.set_level(logging.DEBUG)
    logging.getLogger("urllib3.connectionpool").disabled = True


@pytest.fixture
def create_container(run_id, docker_client, docker_network):
    containers = []

    @retry(3, APIError, 0.2)
    def really_create_container(image, expose_port, **kwargs):
        nonlocal containers
        kw = {**kwargs}
        if expose_port:
            kw.setdefault("ports", {})[f"{expose_port}/tcp"] = None
        logging.debug(
            f"create container: %s",
            dict(
                image=image, detach=True, mem_limit="256m", network=docker_network, **kw,
            ),
        )
        c = docker_client.containers.create(
            image, detach=True, mem_limit="256m", network=docker_network, **kw,
        )
        c.reload()
        containers.append(c)
        return c

    yield really_create_container
    for c in containers:
        c.remove(force=True, v=True)


@pytest.fixture
def run_container(create_container):
    def really_run_container(image, expose_port, **kwargs):
        c = create_container(image, expose_port, **kwargs)
        c.start()
        c.reload()
        if expose_port:
            wait_tcp_port("localhost", get_port_on_host(c, expose_port))
        return c

    return really_run_container
